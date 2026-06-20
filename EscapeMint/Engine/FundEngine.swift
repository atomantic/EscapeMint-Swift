import Foundation

// MARK: - Financial Constants

/// Shared thresholds and conversion factors used across fund computations.
/// Named here so the same tolerance/period is applied consistently everywhere.
enum FundMath {
    /// Days per year used for all APY annualization.
    static let daysPerYear = 365.0
    /// Share/contract balance below this magnitude is treated as a fully-closed position.
    static let shareDustThreshold = 0.0001
    /// Currency tolerance (1 cent) for value-based liquidation and cash-availability checks.
    static let currencyTolerance = 0.01
    /// Floor for a return rate before annualizing — caps a total loss at -99% so `pow` stays finite.
    static let minReturnRate = -0.99
}

// MARK: - Share Tracking & Liquidation Detection

func trackShares(trade: Trade, currentShares: Double) -> Double {
    guard let shares = trade.shares else { return currentShares }
    let sharesAbs = abs(shares)
    return currentShares + (trade.type == .sell ? -sharesAbs : sharesAbs)
}

/// Share/value-based liquidation test (no dollar-flow condition) used while walking
/// entries one cycle at a time. A SELL fully closes the position when the remaining
/// share balance is dust OR the post-sale value is within a cent of the sale amount.
func isShareOrValueLiquidation(shares: Double?, remainingShares: Double, value: Double, amount: Double) -> Bool {
    let hasShareTracking = shares != nil && (shares ?? 0) != 0
    let sharesLiquidated = hasShareTracking && abs(remainingShares) < FundMath.shareDustThreshold
    let valueLiquidated = value > 0 && value <= amount + FundMath.currencyTolerance
    return sharesLiquidated || valueLiquidated
}

/// Full liquidation including the dollar-flow condition: a position is also considered
/// closed once cumulative sells meet or exceed cumulative buys.
func isFullLiquidation(shares: Double?, value: Double, amount: Double, sumShares: Double, totalBuys: Double, totalSells: Double) -> Bool {
    isShareOrValueLiquidation(shares: shares, remainingShares: sumShares, value: value, amount: amount) || totalSells >= totalBuys
}

func detectFullLiquidation(trade: Trade, sumShares: Double, totalBuys: Double, totalSells: Double) -> Bool {
    isFullLiquidation(shares: trade.shares, value: trade.value ?? 0, amount: trade.amountUsd, sumShares: sumShares, totalBuys: totalBuys, totalSells: totalSells)
}

// MARK: - Core Computations

func computeStartInput(trades: [Trade], asOfDate: String, config: FundConfig? = nil) -> Double {
    let isAccumulateMode = config?.accumulate == true
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0

    let sorted = trades.filter { daysBetween($0.date, asOfDate) >= 0 }
        .sorted { $0.date < $1.date }

    for trade in sorted {
        sumShares = trackShares(trade: trade, currentShares: sumShares)

        if trade.type == .buy {
            totalBuys += trade.amountUsd
        } else {
            totalSells += trade.amountUsd
            let hasShareTracking = trade.shares != nil && trade.shares != 0
            if detectFullLiquidation(trade: trade, sumShares: sumShares, totalBuys: totalBuys, totalSells: totalSells) {
                totalBuys = 0
                totalSells = 0
                sumShares = 0
            } else if !isAccumulateMode && hasShareTracking && totalBuys > 0 {
                // Harvest mode: reduce cost basis proportionally
                let sharesBeforeSell = sumShares + abs(trade.shares ?? 0)
                let sellFraction = sharesBeforeSell > 0 ? abs(trade.shares ?? 0) / sharesBeforeSell : 1.0
                let costBasisSold = totalBuys * sellFraction
                totalBuys -= costBasisSold
                totalSells = 0
            } else if isAccumulateMode {
                totalSells = 0
            }
        }
    }

    return max(0, totalBuys - totalSells)
}

func computeExpectedTarget(config: FundConfig, trades: [Trade], asOfDate: String) -> Double {
    let targetApy = config.target_apy ?? 0
    var startInput = 0.0
    var expectedGain = 0.0
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0

    let sorted = trades.sorted { $0.date < $1.date }

    for trade in sorted {
        let tradeDays = daysBetween(trade.date, asOfDate)
        if tradeDays < 0 { continue }

        sumShares = trackShares(trade: trade, currentShares: sumShares)

        if trade.type == .buy {
            totalBuys += trade.amountUsd
            startInput += trade.amountUsd
            let gain = trade.amountUsd * (pow(1.0 + targetApy, Double(tradeDays) / FundMath.daysPerYear) - 1.0)
            expectedGain += gain
        } else {
            totalSells += trade.amountUsd
            let hasShareTracking = trade.shares != nil && trade.shares != 0
            if detectFullLiquidation(trade: trade, sumShares: sumShares, totalBuys: totalBuys, totalSells: totalSells) {
                startInput = 0
                expectedGain = 0
                totalBuys = 0
                totalSells = 0
                sumShares = 0
            } else {
                let isAccumulateMode = config.accumulate == true
                if isAccumulateMode {
                    totalSells = 0
                } else if startInput > 0 {
                    var sellFraction: Double
                    if hasShareTracking {
                        let sharesBeforeSell = sumShares + abs(trade.shares ?? 0)
                        sellFraction = sharesBeforeSell > 0 ? abs(trade.shares ?? 0) / sharesBeforeSell : 1.0
                    } else {
                        sellFraction = min(1.0, trade.amountUsd / startInput)
                    }
                    expectedGain *= (1 - sellFraction)
                    startInput = max(0, startInput * (1 - sellFraction))
                }
            }
        }
    }

    return startInput + expectedGain
}

func computeCashAvailable(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], asOfDate: String) -> Double {
    let interest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
    return computeCashAvailableWithInterest(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, asOfDate: asOfDate, precomputedInterest: interest)
}

private func computeCashAvailableWithInterest(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], asOfDate: String, precomputedInterest: Double) -> Double {
    let startInput = computeStartInput(trades: trades, asOfDate: asOfDate, config: config)
    var cash = -startInput

    for cf in cashflows where daysBetween(cf.date, asOfDate) >= 0 {
        if cf.type == .deposit { cash += cf.amountUsd }
        else { cash -= cf.amountUsd }
    }

    let dividendReinvest = config.dividend_reinvest != false
    let interestReinvest = config.interest_reinvest != false
    let expenseFromFund = config.expense_from_fund != false

    if dividendReinvest {
        for d in dividends where daysBetween(d.date, asOfDate) >= 0 {
            cash += d.amountUsd
        }
    }

    if interestReinvest {
        cash += precomputedInterest
    }

    if expenseFromFund {
        for e in expenses where daysBetween(e.date, asOfDate) >= 0 {
            cash -= e.amountUsd
        }
    }

    return max(0, cash)
}

func computeCashInterest(config: FundConfig, trades: [Trade], cashflows: [CashFlow], asOfDate: String) -> Double {
    let cashApy = config.cash_apy ?? 0
    if cashApy == 0 { return 0 }

    var events: [(date: String, sign: Double, amount: Double)] = []

    for trade in trades {
        events.append((trade.date, trade.type == .buy ? -1 : 1, trade.amountUsd))
    }
    for cf in cashflows {
        events.append((cf.date, cf.type == .deposit ? 1 : -1, cf.amountUsd))
    }

    events.sort { $0.date < $1.date }

    var totalInterest = 0.0
    var currentCash = 0.0
    var lastDate = events.first?.date ?? asOfDate

    for event in events {
        if daysBetween(event.date, asOfDate) < 0 { continue }
        if daysBetween(lastDate, event.date) < 0 { continue }

        let periodDays = daysBetween(lastDate, event.date)
        if periodDays > 0 && currentCash > 0 {
            totalInterest += currentCash * (pow(1.0 + cashApy, Double(periodDays) / FundMath.daysPerYear) - 1.0)
        }

        currentCash += event.sign * event.amount
        currentCash = max(0, currentCash)
        lastDate = event.date
    }

    let finalDays = daysBetween(lastDate, asOfDate)
    if finalDays > 0 && currentCash > 0 {
        totalInterest += currentCash * (pow(1.0 + cashApy, Double(finalDays) / FundMath.daysPerYear) - 1.0)
    }

    return totalInterest
}

func computeRealizedGains(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], asOfDate: String) -> Double {
    let interest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
    return computeRealizedGainsWithInterest(config: config, trades: trades, dividends: dividends, expenses: expenses, asOfDate: asOfDate, precomputedInterest: interest)
}

private func computeRealizedGainsWithInterest(config: FundConfig, trades: [Trade], dividends: [Dividend], expenses: [Expense], asOfDate: String, precomputedInterest: Double) -> Double {
    var realized = 0.0
    let sorted = trades.filter { daysBetween($0.date, asOfDate) >= 0 }
        .sorted { $0.date < $1.date }

    var totalBuys = 0.0
    var totalSells = 0.0

    for trade in sorted {
        if trade.type == .buy {
            totalBuys += trade.amountUsd
        } else {
            totalSells += trade.amountUsd
            if totalSells >= totalBuys {
                realized += totalSells - totalBuys
                totalBuys = 0
                totalSells = 0
            }
        }
    }

    realized += precomputedInterest

    for d in dividends where daysBetween(d.date, asOfDate) >= 0 {
        realized += d.amountUsd
    }

    let expenseFromFund = config.expense_from_fund != false
    if expenseFromFund {
        for e in expenses where daysBetween(e.date, asOfDate) >= 0 {
            realized -= e.amountUsd
        }
    }

    return realized
}

func computeFundState(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], actualValue: Double, asOfDate: String) -> FundState {
    // Cash funds: value IS the cash balance
    if isCashFund(config.fund_type) {
        let cashInterest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
        let startInput = actualValue - cashInterest
        let gainPct = startInput > 0 && cashInterest.isFinite ? cashInterest / startInput : 0
        return FundState(
            cashAvailableUsd: actualValue,
            expectedTargetUsd: 0,
            actualValueUsd: actualValue,
            startInputUsd: startInput,
            gainUsd: cashInterest,
            gainPct: gainPct,
            targetDiffUsd: 0,
            cashInterestUsd: cashInterest,
            realizedGainsUsd: cashInterest
        )
    }

    // Closed funds: zeroed state
    if config.status == .closed {
        return FundState(
            cashAvailableUsd: 0,
            expectedTargetUsd: 0,
            actualValueUsd: actualValue,
            startInputUsd: 0,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: 0,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )
    }

    let startInput = computeStartInput(trades: trades, asOfDate: asOfDate, config: config)
    let expectedTarget = computeExpectedTarget(config: config, trades: trades, asOfDate: asOfDate)
    let cashInterest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
    let cashAvailable = computeCashAvailableWithInterest(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, asOfDate: asOfDate, precomputedInterest: cashInterest)
    let realizedGains = computeRealizedGainsWithInterest(config: config, trades: trades, dividends: dividends, expenses: expenses, asOfDate: asOfDate, precomputedInterest: cashInterest)

    let gainUsd = startInput > 0 ? actualValue - startInput : 0
    let rawGainPct = startInput > 0 ? (actualValue / startInput) - 1.0 : 0
    let gainPct = rawGainPct.isFinite ? rawGainPct : 0
    let targetDiff = actualValue - expectedTarget

    return FundState(
        cashAvailableUsd: cashAvailable,
        expectedTargetUsd: expectedTarget,
        actualValueUsd: actualValue,
        startInputUsd: startInput,
        gainUsd: gainUsd,
        gainPct: gainPct,
        targetDiffUsd: targetDiff,
        cashInterestUsd: cashInterest,
        realizedGainsUsd: realizedGains
    )
}

// MARK: - Closed Fund Metrics

func computeClosedFundMetrics(trades: [Trade], dividends: [Dividend], expenses: [Expense], cashInterest: Double, startDate: String, endDate: String) -> ClosedFundMetrics {
    var totalInvested = 0.0
    var totalReturned = 0.0

    for trade in trades {
        if trade.type == .buy { totalInvested += trade.amountUsd }
        else { totalReturned += trade.amountUsd }
    }

    let totalDividends = dividends.reduce(0.0) { $0 + $1.amountUsd }
    let totalExpenses = expenses.reduce(0.0) { $0 + $1.amountUsd }
    let netGain = totalReturned + totalDividends + cashInterest - totalExpenses - totalInvested
    let returnPct = totalInvested > 0 ? netGain / totalInvested : 0
    let durationDays = daysBetween(startDate, endDate)
    let clampedReturn = max(FundMath.minReturnRate, returnPct)
    let apy = durationDays > 3 ? pow(1.0 + clampedReturn, FundMath.daysPerYear / Double(durationDays)) - 1.0 : clampedReturn

    return ClosedFundMetrics(
        totalInvestedUsd: totalInvested,
        totalReturnedUsd: totalReturned,
        totalDividendsUsd: totalDividends,
        totalCashInterestUsd: cashInterest,
        totalExpensesUsd: totalExpenses,
        netGainUsd: netGain,
        returnPct: returnPct,
        apy: apy,
        startDate: startDate,
        endDate: endDate,
        durationDays: durationDays
    )
}

// MARK: - Recommendation

func computeLimit(config: FundConfig, state: FundState) -> Double {
    let minUsd = config.input_min_usd ?? 0
    let midUsd = config.input_mid_usd ?? 0
    let maxUsd = config.input_max_usd ?? 0
    let maxAtPct = config.max_at_pct ?? -0.25

    if state.startInputUsd == 0 { return minUsd }
    if state.gainUsd < 0 && state.gainPct <= maxAtPct { return maxUsd }
    if state.gainUsd < 0 { return midUsd }
    return minUsd
}

func computeRecommendation(config: FundConfig, state: FundState) -> Recommendation? {
    guard let fundType = config.fund_type else { return nil }
    if isCashFund(fundType) { return nil }
    if fundType == .derivatives { return nil }
    if config.status == .closed { return nil }

    let features = getFeatures(fundType)
    guard features.allowsRecommendations else { return nil }

    let limit = computeLimit(config: config, state: state)
    let hasCashPool = config.manage_cash ?? true

    // Special case: no investment yet, recommend initial BUY
    if state.startInputUsd == 0 && state.actualValueUsd == 0 {
        // Check if cash is available (either in-fund or platform-level)
        if state.cashAvailableUsd < FundMath.currencyTolerance {
            return Recommendation(action: .HOLD, amount: 0,
                                  reasoning: "No cash available. Deposit funds to your platform cash account before your first DCA purchase.")
        }
        let buyAmount = hasCashPool ? min(limit, state.cashAvailableUsd) : min(limit, state.cashAvailableUsd)
        return Recommendation(action: .BUY, amount: buyAmount,
                              reasoning: "No position yet. System calculates initial DCA of \(formatCurrency(buyAmount)).")
    }

    // SELL: above target by more than min_profit AND in profit
    let minProfit = config.min_profit_usd ?? 0
    if state.targetDiffUsd > minProfit && state.gainUsd > 0 {
        let accumulate = config.accumulate == true
        let sellAmount = accumulate ? limit : state.actualValueUsd
        let prefix = "Above target by \(formatCurrency(state.targetDiffUsd)) (> \(formatCurrency(minProfit)) threshold)."
        let reasoning = accumulate
            ? "\(prefix) Rules calculate sell of \(formatCurrency(sellAmount))."
            : "\(prefix) Rules calculate full harvest of \(formatCurrency(state.actualValueUsd))."
        return Recommendation(action: .SELL, amount: sellAmount, reasoning: reasoning)
    }

    // BUY: below or at target
    let buyAmount = min(limit, state.cashAvailableUsd)

    // No cash available — HOLD
    if buyAmount < FundMath.currencyTolerance {
        return Recommendation(action: .HOLD, amount: 0, reasoning: "No cash available for DCA. Deposit funds to your platform cash account.")
    }

    let reasoning: String
    if state.gainUsd < 0 && state.gainPct < (config.max_at_pct ?? -0.25) {
        reasoning = "Significant loss (\(formatPercent(state.gainPct))). Rules calculate max DCA of \(formatCurrency(limit))."
    } else if state.gainUsd < 0 {
        reasoning = "Below cost basis (\(formatPercent(state.gainPct)) loss). Rules calculate mid DCA of \(formatCurrency(limit))."
    } else {
        reasoning = "On track or above cost. Rules calculate min DCA of \(formatCurrency(limit))."
    }

    return Recommendation(action: .BUY, amount: buyAmount, reasoning: reasoning)
}

// MARK: - Aggregate (Time-Weighted Fund Size)

func computeTimeWeightedFundSize(trades: [Trade], startDate: String, asOfDate: String) -> Double {
    let totalDays = daysBetween(startDate, asOfDate)
    if totalDays <= 0 { return 0 }

    let sorted = trades.sorted { $0.date < $1.date }
    var cumulativeInvestment = 0.0
    var weightedSum = 0.0
    var lastDate = startDate

    for trade in sorted {
        if daysBetween(trade.date, asOfDate) < 0 { continue }
        if daysBetween(startDate, trade.date) < 0 { continue }
        let periodDays = daysBetween(lastDate, trade.date)
        if periodDays > 0 {
            weightedSum += cumulativeInvestment * Double(periodDays)
        }
        if trade.type == .buy { cumulativeInvestment += trade.amountUsd }
        else { cumulativeInvestment -= trade.amountUsd }
        cumulativeInvestment = max(0, cumulativeInvestment)
        lastDate = trade.date
    }

    let remaining = daysBetween(lastDate, asOfDate)
    if remaining > 0 {
        weightedSum += cumulativeInvestment * Double(remaining)
    }

    return weightedSum / Double(totalDays)
}

func computeCashFundTimeWeightedSize(cashFlows: [CashFlow], startDate: String, asOfDate: String) -> Double {
    let totalDays = daysBetween(startDate, asOfDate)
    if totalDays <= 0 { return 0 }

    let sorted = cashFlows.sorted { $0.date < $1.date }
    var balance = 0.0
    var weightedSum = 0.0
    var lastDate = startDate

    for flow in sorted {
        if daysBetween(flow.date, asOfDate) < 0 { continue }
        if daysBetween(startDate, flow.date) < 0 { continue }
        let periodDays = daysBetween(lastDate, flow.date)
        if periodDays > 0 {
            weightedSum += balance * Double(periodDays)
        }
        if flow.type == .deposit { balance += flow.amountUsd }
        else { balance -= flow.amountUsd }
        balance = max(0, balance)
        lastDate = flow.date
    }

    let remaining = daysBetween(lastDate, asOfDate)
    if remaining > 0 {
        weightedSum += balance * Double(remaining)
    }

    return weightedSum / Double(totalDays)
}

// MARK: - Per-Fund APY (linear, matches web app)

func computeLinearAPY(_ gain: Double, _ basis: Double, _ days: Int) -> Double {
    if basis <= 0 || days <= 0 { return 0 }
    return (gain / basis) * (FundMath.daysPerYear / Double(days))
}

func computeCompoundAPY(_ returnPct: Double, _ days: Int) -> Double {
    guard days > 0 else { return 0 }
    return pow(1.0 + max(FundMath.minReturnRate, returnPct), FundMath.daysPerYear / Double(days)) - 1.0
}

func computeProjectedAnnualReturn(_ currentValue: Double, _ realizedAPY: Double) -> Double {
    currentValue * realizedAPY
}

// MARK: - Full Fund Metrics (single-pass, matches web app fund-metrics.ts)

func computeFundMetricsForFund(_ fund: FundData, asOfDate: String) -> (metrics: FundMetrics, state: FundState) {
    let config = fund.config

    // Derivatives funds have entirely different semantics — handle separately
    if config.fund_type == .derivatives {
        return computeDerivativesFundMetrics(fund, asOfDate: asOfDate)
    }

    let isCash = isCashFund(config.fund_type)
    let isAccumulate = config.accumulate == true
    let manageCash = config.manage_cash != false

    // Sort entries chronologically
    let entries = fund.entries.sorted { $0.date < $1.date }

    // Single-pass entry walking (matches web app's computeFundFinalMetrics)
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0
    var costBasis = 0.0
    var sumDividends = 0.0
    var sumExpenses = 0.0
    var sumCashInterest = 0.0
    var sumExtracted = 0.0

    // TWAP tracking (trading funds)
    var twapNumerator = 0.0
    var twapLastDate: String?

    // TWAB tracking (cash funds)
    var twabNumerator = 0.0
    var lastCashBalance = 0.0
    var lastDate: String?

    // Active days: only count time when capital is deployed
    var cycleStartDate: String?
    var cumulativeActiveDays = 0.0
    var hadFirstBuy = false

    for entry in entries {
        // TWAB for cash funds
        if let ld = lastDate, isCash {
            let daysBtw = max(0, Double(daysBetween(ld, entry.date)))
            twabNumerator += lastCashBalance * daysBtw
        }

        // Track shares
        if let shares = entry.shares {
            if entry.action == .BUY { sumShares += shares }
            else if entry.action == .SELL { sumShares -= shares }
        }

        // Cumulative income/expenses
        if let d = entry.dividend { sumDividends += d }
        if let e = entry.expense { sumExpenses += e }
        if let ci = entry.cash_interest { sumCashInterest += ci }

        // TWAP before processing this entry's action
        if !isCash, let tld = twapLastDate, cycleStartDate != nil {
            let daysBtw = max(0, Double(daysBetween(tld, entry.date)))
            twapNumerator += costBasis * daysBtw
        }
        if cycleStartDate != nil { twapLastDate = entry.date }

        // Process buys and sells
        if entry.action == .BUY, let amt = entry.amount {
            totalBuys += amt
            costBasis += amt
            if cycleStartDate == nil {
                cycleStartDate = entry.date
                twapLastDate = entry.date
                hadFirstBuy = true
            }
        } else if entry.action == .SELL, let amt = entry.amount {
            let isFullLiq = isShareOrValueLiquidation(shares: entry.shares, remainingShares: sumShares, value: entry.value, amount: amt)

            var extracted = 0.0
            if isFullLiq {
                extracted = amt - costBasis
                costBasis = 0
                totalBuys = 0
                totalSells = 0
                sumShares = 0
                // Freeze active days on full liquidation
                if let csd = cycleStartDate {
                    cumulativeActiveDays += max(0, Double(daysBetween(csd, entry.date)))
                    cycleStartDate = nil
                }
            } else if isAccumulate {
                extracted = amt
            } else {
                // Harvest mode: proportional cost basis
                let sellProportion = (entry.value + amt) > 0 ? amt / (entry.value + amt) : 1.0
                let costBasisReturned = costBasis * sellProportion
                extracted = amt - costBasisReturned
                costBasis -= costBasisReturned
                totalSells += amt
            }
            sumExtracted += extracted
        }

        // TWAB tracking
        if isCash {
            lastCashBalance = entry.cash ?? entry.value
        }
        lastDate = entry.date
    }

    // Final TWAP period
    let latestEntry = entries.last
    // Active funds use asOfDate (today) for TWAP/daysActive — matches web app.
    // Closed funds use last entry date since no capital is deployed after closure.
    let endDate = config.status == .closed ? (latestEntry?.date ?? asOfDate) : asOfDate
    if !isCash, let tld = twapLastDate, cycleStartDate != nil {
        let finalDays = max(0, Double(daysBetween(tld, endDate)))
        twapNumerator += costBasis * finalDays
    }

    // Compute active days
    let daysActive: Int
    if hadFirstBuy {
        let currentCycleDays = cycleStartDate.map { max(0, Double(daysBetween($0, endDate))) } ?? 0
        daysActive = max(1, Int(cumulativeActiveDays + currentCycleDays))
    } else {
        let sd = entries.first?.date ?? asOfDate
        daysActive = max(1, daysBetween(sd, endDate))
    }

    // Calculate final values
    let netInvested = max(0, totalBuys - totalSells)

    let computedFundSize: Double
    let currentValue: Double
    let cash: Double

    if config.status == .closed {
        computedFundSize = 0
        currentValue = 0
        cash = 0
    } else if isCash {
        // Use first non-zero value: cash → fund_size → value
        // (cash field may be explicitly 0 from older entries, so ?? alone won't fall through)
        let cashVal: Double
        if let c = latestEntry?.cash, c > 0 { cashVal = c }
        else if let fs = latestEntry?.fund_size, fs > 0 { cashVal = fs }
        else { cashVal = latestEntry?.value ?? 0 }
        cash = cashVal
        computedFundSize = latestEntry?.fund_size ?? cashVal
        currentValue = cashVal
    } else {
        // Trading fund: compute post-action value
        var postActionValue = latestEntry?.value ?? 0
        if latestEntry?.action == .BUY, let amt = latestEntry?.amount {
            postActionValue += amt
        } else if latestEntry?.action == .SELL, let amt = latestEntry?.amount {
            postActionValue = max(0, postActionValue - amt)
        }
        currentValue = postActionValue

        if !manageCash {
            computedFundSize = latestEntry?.fund_size ?? netInvested
        } else {
            computedFundSize = latestEntry?.fund_size ?? 0
        }

        if !manageCash {
            cash = 0
        } else {
            cash = latestEntry?.cash ?? max(0, computedFundSize - netInvested)
        }
    }

    // Gains
    let unrealized = isCash ? 0 : (currentValue - costBasis)
    let realized = isCash
        ? sumCashInterest - sumExpenses
        : sumCashInterest + sumDividends + sumExtracted - sumExpenses
    let liquidPnl = unrealized + realized

    // APY
    var realizedAPY = 0.0
    var liquidAPY = 0.0

    if isCash {
        let twab = Double(daysActive) > 0 ? twabNumerator / Double(daysActive) : 0
        let denominator = twab > 0 ? twab : (computedFundSize > 0 ? computedFundSize : 1)
        if abs(realized) >= FundMath.currencyTolerance {
            realizedAPY = computeCompoundAPY(realized / denominator, daysActive)
            liquidAPY = realizedAPY
        }
    } else {
        let twap = Double(daysActive) > 0 ? twapNumerator / Double(daysActive) : 0
        let denominator = twap > 0 ? twap : (costBasis > 0 ? costBasis : 1)
        if denominator > 0 {
            realizedAPY = computeCompoundAPY(realized / denominator, daysActive)
            liquidAPY = computeCompoundAPY(liquidPnl / denominator, daysActive)
        }
    }

    let gainUsd = isCash ? realized : unrealized
    let projectedAnnualReturn = computeProjectedAnnualReturn(currentValue, realizedAPY)
    let twfs = daysActive > 0 ? (isCash ? twabNumerator : twapNumerator) / Double(daysActive) : 0

    // Build FundState directly from single-pass data (avoids redundant entry walks).
    // Recommendation decisions must use the open position's cost basis, not net
    // invested after prior harvests. Otherwise realized profit can mask a current
    // unrealized loss and incorrectly permit a SELL recommendation.
    let startInput = isCash ? cash : costBasis
    let gainUsdState = startInput > 0 ? currentValue - startInput : 0.0
    let rawGainPct = startInput > 0 ? (currentValue / startInput) - 1.0 : 0.0
    let gainPctState = rawGainPct.isFinite ? rawGainPct : 0.0

    // Only compute expectedTarget/cashAvailable for recommendation engine (active non-cash funds)
    let needsRecommendation = config.status != .closed && !isCash && config.fund_type != .derivatives
    var expectedTarget = 0.0
    var cashAvailable = cash

    if needsRecommendation {
        let trades = entriesToTrades(fund.entries)
        let cashflows = entriesToCashFlows(fund.entries)
        let divs = entriesToDividends(fund.entries)
        let exps = entriesToExpenses(fund.entries)
        expectedTarget = computeExpectedTarget(config: config, trades: trades, asOfDate: asOfDate)

        cashAvailable = computeCashAvailable(config: config, trades: trades, cashflows: cashflows, dividends: divs, expenses: exps, asOfDate: asOfDate)
    }

    let state = FundState(
        cashAvailableUsd: cashAvailable,
        expectedTargetUsd: expectedTarget,
        actualValueUsd: currentValue,
        startInputUsd: startInput,
        gainUsd: gainUsdState,
        gainPct: gainPctState,
        targetDiffUsd: currentValue - expectedTarget,
        cashInterestUsd: sumCashInterest,
        realizedGainsUsd: realized
    )

    let metrics = FundMetrics(
        id: fund.id,
        platform: fund.platform,
        ticker: fund.ticker,
        status: config.status ?? .active,
        fundType: config.fund_type ?? .stock,
        category: config.category,
        fundSize: computedFundSize,
        currentValue: currentValue,
        startInput: startInput,
        daysActive: daysActive,
        timeWeightedFundSize: twfs,
        realizedGains: realized,
        unrealizedGains: unrealized,
        realizedAPY: realizedAPY,
        liquidAPY: liquidAPY,
        projectedAnnualReturn: projectedAnnualReturn,
        gainUsd: gainUsd,
        gainPct: gainPctState,
        totalDividends: sumDividends,
        totalExpenses: sumExpenses,
        totalCashInterest: sumCashInterest,
        cash: cash,
        fundShares: 0,
        fundSharesPct: 0
    )
    return (metrics, state)
}

// MARK: - Cash Fund Resolution

/// Resolve the cash fund ID for a fund that doesn't manage its own cash.
func resolveCashFundId(config: FundConfig, platform: String) -> String {
    config.cash_fund ?? "\(platform)-cash"
}

// MARK: - Actionable Funds (Attention Alerts)

struct ActionableFund: Identifiable {
    let id: String
    let fund: FundData
    let daysOverdue: Int      // positive = overdue, 0 = due today, negative = upcoming
    let intervalDays: Int
    let needsCashDeposit: Bool // true = this is a cash fund that needs funding

    init(id: String, fund: FundData, daysOverdue: Int, intervalDays: Int, needsCashDeposit: Bool = false) {
        self.id = id
        self.fund = fund
        self.daysOverdue = daysOverdue
        self.intervalDays = intervalDays
        self.needsCashDeposit = needsCashDeposit
    }

    var urgency: Urgency {
        if needsCashDeposit { return .overdue }
        if daysOverdue > 0 { return .overdue }
        if daysOverdue == 0 { return .dueToday }
        return .upcoming
    }

    enum Urgency {
        case overdue, dueToday, upcoming
    }
}

func computeActionableFunds(_ funds: [FundData], asOfDate: String? = nil) -> [ActionableFund] {
    let today = asOfDate ?? todayString()
    let fundById = Dictionary(uniqueKeysWithValues: funds.map { ($0.id, $0) })
    var latestEntryByFundId: [String: FundEntry] = [:]
    latestEntryByFundId.reserveCapacity(funds.count)
    for fund in funds {
        if let latest = fund.entries.max(by: { $0.date < $1.date }) {
            latestEntryByFundId[fund.id] = latest
        }
    }

    var results: [ActionableFund] = []
    var cashFundsNeeded: Set<String> = [] // platform cash fund IDs that need deposits

    // First pass: find trading funds that are actionable
    for fund in funds {
        let config = fund.config
        guard config.status != .closed,
              !isCashFund(config.fund_type),
              config.fund_type != .derivatives,
              let intervalDays = config.interval_days,
              intervalDays > 0 else { continue }

        // Stock funds: skip on weekends and US market holidays
        if config.fund_type == .stock && !isStockTradingDay(today) { continue }

        // Check if due
        let isDue: Bool
        let daysOverdue: Int
        if let lastEntry = fund.entries.last {
            let daysSince = daysBetween(lastEntry.date, today)
            daysOverdue = daysSince - intervalDays
            isDue = daysOverdue >= 0
        } else {
            // New fund with no entries — always due
            daysOverdue = 0
            isDue = true
        }
        guard isDue else { continue }

        // Check if this fund needs platform cash.
        // A fund only requires the cash fund to be funded if it can't cover
        // the buy from other sources (e.g. available margin). If margin is
        // enabled and has headroom, the trading fund can execute without the
        // cash fund holding a balance, so don't trigger a cash-deposit alert.
        if config.manage_cash == false {
            let cashFundId = resolveCashFundId(config: config, platform: fund.platform)
            let cashBalance: Double
            if let latestCash = latestEntryByFundId[cashFundId] {
                cashBalance = latestCash.cash ?? latestCash.value
            } else {
                cashBalance = 0
            }

            var effectiveAvailable = cashBalance
            if config.margin_enabled == true,
               let latestEntry = latestEntryByFundId[fund.id],
               let marginAvail = latestEntry.margin_available, marginAvail > 0 {
                effectiveAvailable += marginAvail
            }

            if effectiveAvailable < FundMath.currencyTolerance {
                cashFundsNeeded.insert(cashFundId)
            }
        }

        results.append(ActionableFund(id: fund.id, fund: fund, daysOverdue: daysOverdue, intervalDays: intervalDays))
    }

    // Second pass: add cash funds that need deposits (at the top)
    var cashActions: [ActionableFund] = []
    for cashId in cashFundsNeeded {
        if let cashFund = fundById[cashId] {
            cashActions.append(ActionableFund(id: cashFund.id, fund: cashFund, daysOverdue: 0, intervalDays: 1, needsCashDeposit: true))
        }
    }

    // Cash funds needing deposits first, then trading funds sorted by overdue
    return cashActions.sorted { $0.fund.platform < $1.fund.platform }
        + results.sorted { $0.daysOverdue > $1.daysOverdue }
}

// MARK: - Per-Entry Computed Data (for entries table columns)

struct ComputedEntryRow {
    let extracted: Double
    let realized: Double
    let liquidPnl: Double
    let realizedApy: Double
    let liquidApy: Double
    let isClosingEntry: Bool
    let invested: Double
    let unrealized: Double
    let sumShares: Double
    let sumExtracted: Double
    let sumExpenses: Double
    let sumCashInterest: Double
    let sumDividends: Double
}

func computeEntryRows(entries: [FundEntry], config: FundConfig) -> [ComputedEntryRow] {
    // Derivatives funds use chart data for per-entry metrics
    if config.fund_type == .derivatives {
        return computeDerivativesEntryRows(entries: entries, config: config)
    }

    let isAccumulate = config.accumulate == true

    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0
    var costBasis = 0.0
    var sumExtracted = 0.0
    var sumDividends = 0.0
    var sumCashInterest = 0.0
    var sumExpenses = 0.0
    var twapNumerator = 0.0
    var twapLastDate: String?
    var cycleStartDate: String?
    var cumulativeActiveDays = 0.0
    let firstEntryDate = entries.first?.date ?? ""

    return entries.enumerated().map { index, entry in
        // Accumulate TWAP only during active cycles (matches web app)
        if let tld = twapLastDate, cycleStartDate != nil {
            let daysBtw = max(0, Double(daysBetween(tld, entry.date)))
            twapNumerator += costBasis * daysBtw
        }
        if cycleStartDate != nil { twapLastDate = entry.date }

        // Active days: cycle-based (matches web app FundDetail.tsx)
        let currentCycleDays = cycleStartDate.map { max(0.0, Double(daysBetween($0, entry.date))) } ?? 0
        let hasAnyActiveHistory = cycleStartDate != nil || cumulativeActiveDays > 0
        let calendarDays = max(1.0, Double(daysBetween(firstEntryDate, entry.date)))
        let activeDays = max(1, Int(round(hasAnyActiveHistory
            ? cumulativeActiveDays + currentCycleDays
            : calendarDays)))
        let isFirstEntry = index == 0

        // Accumulate income/expenses
        sumDividends += entry.dividend ?? 0
        sumCashInterest += entry.cash_interest ?? 0
        sumExpenses += entry.expense ?? 0

        var entryExtracted = 0.0
        var isClosing = false

        if entry.action == .BUY, let amt = entry.amount {
            totalBuys += amt
            costBasis += amt
            sumShares += abs(entry.shares ?? 0)
            if cycleStartDate == nil {
                cycleStartDate = entry.date
                twapLastDate = entry.date
            }
        } else if entry.action == .SELL, let amt = entry.amount {
            totalSells += amt
            sumShares -= abs(entry.shares ?? 0)

            if isFullLiquidation(shares: entry.shares, value: entry.value, amount: amt, sumShares: sumShares, totalBuys: totalBuys, totalSells: totalSells) {
                isClosing = true
                entryExtracted = max(0, totalSells - totalBuys)
                sumExtracted += entryExtracted
                costBasis = 0
                totalBuys = 0
                totalSells = 0
                sumShares = 0
                // Freeze active days and TWAP on full liquidation
                if let csd = cycleStartDate {
                    cumulativeActiveDays += max(0, Double(daysBetween(csd, entry.date)))
                    cycleStartDate = nil
                    twapLastDate = nil
                }
            } else if isAccumulate {
                entryExtracted = amt
                sumExtracted += entryExtracted
                totalSells = 0
            } else {
                // Harvest mode: proportional cost basis (value-based, matches web app)
                let sellProportion = (entry.value + amt) > 0 ? amt / (entry.value + amt) : 1.0
                let costBasisReturned = costBasis * sellProportion
                entryExtracted = max(0, amt - costBasisReturned)
                sumExtracted += entryExtracted
                costBasis -= costBasisReturned
                totalSells = 0
            }
        }

        let realized = sumExtracted + sumDividends + sumCashInterest - sumExpenses

        // Post-action equity value (entry.value is pre-action, matches web app FundDetail.tsx)
        var postActionValue = entry.value
        if entry.action == .BUY, let amt = entry.amount {
            postActionValue = entry.value + amt
        } else if entry.action == .SELL, let amt = entry.amount {
            postActionValue = max(0, entry.value - amt)
        }
        let unrealized = postActionValue - costBasis
        let liquidPnl = unrealized + realized

        // Compound APY with cycle-based active days (matches web app per-entry formula)
        let twap = activeDays > 0 ? twapNumerator / Double(activeDays) : 0
        let basis = twap > 0 ? twap : costBasis

        var realizedApy = 0.0
        var liquidApy = 0.0

        if !isFirstEntry && activeDays > 0 && basis > 0 {
            realizedApy = computeCompoundAPY(realized / basis, activeDays)
            liquidApy = computeCompoundAPY(liquidPnl / basis, activeDays)
        }

        return ComputedEntryRow(
            extracted: entryExtracted,
            realized: realized,
            liquidPnl: liquidPnl,
            realizedApy: realizedApy,
            liquidApy: liquidApy,
            isClosingEntry: isClosing,
            invested: costBasis,
            unrealized: unrealized,
            sumShares: sumShares,
            sumExtracted: sumExtracted,
            sumExpenses: sumExpenses,
            sumCashInterest: sumCashInterest,
            sumDividends: sumDividends
        )
    }
}
