import Foundation

// MARK: - Latest Entry

extension Array where Element == FundEntry {
    /// Latest entry by date, with same-date ties resolving to the last-appended
    /// entry (matching `entries.last` semantics used when writing). `max(by:)`
    /// keeps the FIRST same-date entry, which masks a later intraday deposit
    /// behind an earlier same-day withdrawal.
    var latestByDate: FundEntry? {
        reduce(nil) { best, entry in
            guard let best else { return entry }
            return entry.date >= best.date ? entry : best
        }
    }
}

// MARK: - Cumulative Shares

/// Compute cumulative shares from entries before a given date
func getCumulativeShares(entries: [FundEntry], beforeDate: String) -> Double {
    let sorted = entries.sorted { $0.date < $1.date }
    var total: Double = 0
    for entry in sorted {
        if entry.date >= beforeDate { break }
        if let s = entry.shares {
            total += entry.action == .SELL ? -abs(s) : abs(s)
        }
    }
    return total
}

// MARK: - Fund Size

/// Parse explicit `Deposit: $X` / `Withdrawal: $Y` amounts embedded in an entry's
/// notes. Returns zeros when the marker is absent or unparseable.
private func parseDepositWithdrawal(from notes: String?) -> (deposit: Double, withdrawal: Double) {
    guard let notes else { return (0, 0) }
    func amount(after label: String) -> Double {
        guard let match = notes.range(of: "\(label):\\s*\\$?([\\d.]+)", options: .regularExpression) else { return 0 }
        let numStr = notes[match]
            .replacingOccurrences(of: "\(label):", with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
        return Double(numStr) ?? 0
    }
    return (amount(after: "Deposit"), amount(after: "Withdrawal"))
}

/// Compute fund_size for an entry based on all entries up to and including it.
/// For manage_cash=false: fund_size = net invested (BUYs - SELLs), resets on full liquidation.
/// For manage_cash=true: fund_size = previous fund_size + deposits - withdrawals (carried forward).
func computeFundSizeForEntry(_ newEntry: FundEntry, existingEntries: [FundEntry], config: FundConfig) -> Double {
    let manageCash = config.manage_cash != false
    let isAccumulate = config.accumulate == true

    // Build the full entry list including the new one, sorted by date
    let allEntries = (existingEntries + [newEntry]).sorted { $0.date < $1.date }
    let priorEntries = existingEntries
        .filter { $0.date <= newEntry.date }
        .sorted { $0.date < $1.date }

    if let previousFundSize = priorEntries.last?.fund_size {
        var fundSize = previousFundSize
        let amount = newEntry.amount ?? 0

        var (depositAmount, withdrawalAmount) = parseDepositWithdrawal(from: newEntry.notes)

        if newEntry.action == .BUY {
            fundSize += amount
        } else if newEntry.action == .SELL {
            var sharesAfter = 0.0
            for entry in priorEntries {
                if let shares = entry.shares {
                    sharesAfter += entry.action == .SELL ? -abs(shares) : abs(shares)
                }
            }
            if let shares = newEntry.shares {
                sharesAfter -= abs(shares)
            }

            if isShareOrValueLiquidation(shares: newEntry.shares, remainingShares: sharesAfter, value: newEntry.value, amount: amount) {
                fundSize = 0
            } else if !isAccumulate {
                fundSize -= amount
            }
        } else if newEntry.action == .DEPOSIT {
            depositAmount = amount
        } else if newEntry.action == .WITHDRAW {
            withdrawalAmount = amount
        }

        if let div = newEntry.dividend, config.dividend_reinvest != false {
            fundSize += abs(div)
        }
        if let ci = newEntry.cash_interest, config.interest_reinvest != false {
            fundSize += abs(ci)
        }
        if let exp = newEntry.expense, config.expense_from_fund != false {
            fundSize -= abs(exp)
        }

        fundSize += depositAmount - withdrawalAmount
        return max(0, (fundSize * 100).rounded() / 100)
    }

    if !manageCash {
        // Non-cash managing: fund_size = cumulative BUYs - SELLs
        var invested = 0.0
        var sumShares = 0.0
        for e in allEntries {
            if e.date > newEntry.date { break }
            if let s = e.shares {
                sumShares += e.action == .SELL ? -abs(s) : abs(s)
            }
            if e.action == .BUY, let amt = e.amount {
                invested += amt
            } else if e.action == .SELL, let amt = e.amount {
                if !isAccumulate {
                    invested -= amt
                }
                // Check full liquidation (share-dust OR value-within-a-cent triggers)
                if isShareOrValueLiquidation(shares: e.shares, remainingShares: sumShares, value: e.value, amount: amt) {
                    invested = 0
                    sumShares = 0
                }
            }
        }
        return max(0, invested)
    } else {
        // Cash managing: carry forward from previous entry, adjust for deposits/withdrawals
        let entriesBefore = allEntries.filter { $0.date < newEntry.date }
        let prevFundSize = entriesBefore.last?.fund_size ?? 0

        // Check for deposit/withdrawal in notes
        var (depositAmount, withdrawalAmount) = parseDepositWithdrawal(from: newEntry.notes)
        if newEntry.action == .DEPOSIT, let amt = newEntry.amount { depositAmount = amt }
        if newEntry.action == .WITHDRAW, let amt = newEntry.amount { withdrawalAmount = amt }

        let adjustment = depositAmount - withdrawalAmount
        return adjustment != 0 ? prevFundSize + adjustment : prevFundSize
    }
}

// MARK: - Cash Sync

/// Why a cash-sync write was not produced — lets the UI layer log a diagnostic
/// without the engine reaching for a Logger.
enum CashSyncSkip: Error {
    case managesOwnCash
    case notATrade
    case noCashFund(cashFundId: String)
}

/// Build the auto-sync cash-fund entry for a trade when the trading fund doesn't
/// manage its own cash. BUY → WITHDRAW from cash, SELL → DEPOSIT to cash.
///
/// Pure core: the caller resolves the platform's cash fund and passes it in. Returns
/// either the pending write (so it can be batched with the trade entry into a single
/// `appendEntries` call) or a `CashSyncSkip` reason for diagnostics.
func buildCashSyncEntry(
    fundId: String,
    entry: FundEntry,
    config: FundConfig,
    cashFund: FundData?
) -> Result<(fundId: String, entry: FundEntry), CashSyncSkip> {
    let manageCash = config.manage_cash != false
    guard !manageCash, let amt = entry.amount, amt > 0,
          (entry.action == .BUY || entry.action == .SELL) else {
        return .failure(manageCash ? .managesOwnCash : .notATrade)
    }

    let platform = fundId.components(separatedBy: "-").first ?? ""
    let cashFundId = "\(platform)-cash"
    guard let cashFund, cashFund.id == cashFundId else {
        return .failure(.noCashFund(cashFundId: cashFundId))
    }

    let ticker = fundId.replacingOccurrences(of: "\(platform)-", with: "").uppercased()
    let isBuy = entry.action == .BUY
    let prevCash = cashFund.entries.last?.cash ?? cashFund.entries.last?.value ?? 0
    let newCash = isBuy ? prevCash - amt : prevCash + amt
    var cashEntry = FundEntry(
        date: entry.date,
        value: max(0, newCash),
        cash: max(0, newCash),
        action: isBuy ? .WITHDRAW : .DEPOSIT,
        amount: amt
    )
    cashEntry.fund_size = cashFund.entries.last?.fund_size ?? 0
    cashEntry.notes = "Auto: \(entry.action?.rawValue ?? "") \(ticker) $\(String(format: "%.2f", amt))"
    return .success((cashFundId, cashEntry))
}

// MARK: - Live Recommendation

/// Pure core of `recommendationForLiveEquity`: compute a live DCA recommendation using a
/// user-supplied current equity, so the guided Add-Entry wizard can show what the engine
/// suggests BEFORE the user records the action.
///
/// Mirrors the state assembly in `FundSummary.init` (FundTypes.swift) but replaces the
/// last-entry-derived `actualValueUsd` with the value the user just reported. Cross-fund
/// cash (for `manage_cash=false` funds) is resolved by the caller and passed in via
/// `externalCashAvailable`.
func recommendationForLiveEquity(
    fund: FundData,
    currentEquity: Double,
    externalCashAvailable: Double?
) -> Recommendation? {
    let today = todayString()
    let trades = entriesToTrades(fund.entries)
    let cashflows = entriesToCashFlows(fund.entries)
    let divs = entriesToDividends(fund.entries)
    let exps = entriesToExpenses(fund.entries)
    var state = computeFundState(
        config: fund.config,
        trades: trades,
        cashflows: cashflows,
        dividends: divs,
        expenses: exps,
        actualValue: currentEquity,
        asOfDate: today
    )

    // For funds that don't manage their own cash, cash lives in the platform cash fund.
    if fund.config.manage_cash == false {
        state.cashAvailableUsd = externalCashAvailable ?? 0
    }

    // Margin-aware: if margin is enabled, treat available margin as borrowable cash.
    if fund.config.margin_enabled == true,
       let latestEntry = fund.entries.last,
       let marginAvail = latestEntry.margin_available, marginAvail > 0 {
        state.cashAvailableUsd += marginAvail
    }

    return computeRecommendation(config: fund.config, state: state)
}
