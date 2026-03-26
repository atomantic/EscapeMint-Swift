import Foundation

// MARK: - Interpolatable Columns

enum InterpolatableColumn: String, CaseIterable {
    case margin_available
    case margin_borrowed
    case fund_size
    case value

    var label: String {
        switch self {
        case .margin_available: return "Margin Available"
        case .margin_borrowed: return "Margin Borrowed"
        case .fund_size: return "Fund Size"
        case .value: return "Value"
        }
    }
}

struct InterpolateResult {
    let column: InterpolatableColumn
    let interpolated: Int
    let totalEntries: Int
    let knownValues: Int
}

// MARK: - Recalculate Fund Size

/// Recalculate fund_size and value for all entries based on trading activity and config.
/// Matches the web app's POST /funds/:id/recalculate logic.
func recalculateFundSize(entries: [FundEntry], config: FundConfig) -> [FundEntry] {
    let isAccumulate = config.accumulate == true
    let dividendReinvest = config.dividend_reinvest != false
    let interestReinvest = config.interest_reinvest != false
    let expenseFromFund = config.expense_from_fund != false

    // Pair each entry with its original index, then sort by date
    var indexed = entries.enumerated().map { (origIdx: $0.offset, entry: $0.element) }
    indexed.sort { $0.entry.date < $1.entry.date }

    var sumBuys = 0.0
    var sumSells = 0.0
    var sumDeposits = 0.0
    var sumWithdrawals = 0.0
    var sumDividends = 0.0
    var sumCashInterest = 0.0
    var sumExpenses = 0.0
    var sumShares = 0.0
    var baseFundSize = 0.0

    for i in 0..<indexed.count {
        let entry = indexed[i].entry

        // Track shares FIRST — BUY adds, SELL subtracts
        if let shares = entry.shares, shares != 0 {
            let sharesAbs = abs(shares)
            sumShares += entry.action == .SELL ? -sharesAbs : sharesAbs
        }

        // Recalculate equity AFTER updating shares: equity = sumShares × price
        if let price = entry.price, price > 0 {
            indexed[i].entry.value = (sumShares * price * 100).rounded() / 100
        }

        // Check for full liquidation
        let hasShareTracking = entry.shares != nil && (entry.shares ?? 0) != 0
        let sharesLiquidated = hasShareTracking && abs(sumShares) < 0.0001
        let valueLiquidated = indexed[i].entry.value > 0 && indexed[i].entry.value <= (entry.amount ?? 0) + 0.01
        let isFullLiq = entry.action == .SELL && (sharesLiquidated || valueLiquidated)

        // Track action amounts
        if entry.action == .BUY, let amt = entry.amount {
            sumBuys += amt
        } else if entry.action == .SELL, let amt = entry.amount {
            if !isAccumulate || isFullLiq {
                sumSells += amt
            }
        } else if entry.action == .DEPOSIT, let amt = entry.amount {
            sumDeposits += amt
        } else if entry.action == .WITHDRAW, let amt = entry.amount {
            sumWithdrawals += amt
        }

        // Track dividends, interest, expenses
        if let div = entry.dividend, dividendReinvest {
            sumDividends += abs(div)
        }
        if let ci = entry.cash_interest, interestReinvest {
            sumCashInterest += abs(ci)
        }
        if let exp = entry.expense, expenseFromFund {
            sumExpenses += abs(exp)
        }

        let newFundSize = baseFundSize
            + sumBuys - sumSells
            + sumDeposits - sumWithdrawals
            + sumDividends + sumCashInterest
            - sumExpenses

        indexed[i].entry.fund_size = max(0, (newFundSize * 100).rounded() / 100)

        // After full liquidation, reset all cumulative values
        if isFullLiq {
            sumBuys = 0; sumSells = 0
            sumDeposits = 0; sumWithdrawals = 0
            sumDividends = 0; sumCashInterest = 0
            sumExpenses = 0; sumShares = 0
            baseFundSize = 0
        }
    }

    // Write results back to original positions by index
    var result = entries
    for item in indexed {
        result[item.origIdx].fund_size = item.entry.fund_size
        result[item.origIdx].value = item.entry.value
    }
    return result
}

// MARK: - Interpolate Column

/// Interpolate missing values for a numeric column using linear interpolation by date.
/// Matches the web app's POST /funds/:id/interpolate logic.
func interpolateColumn(_ column: InterpolatableColumn, entries: [FundEntry]) -> (entries: [FundEntry], result: InterpolateResult) {
    guard !entries.isEmpty else {
        return (entries, InterpolateResult(column: column, interpolated: 0, totalEntries: 0, knownValues: 0))
    }

    // Pair each entry with its original index, then sort by date
    var indexed = entries.enumerated().map { (origIdx: $0.offset, entry: $0.element) }
    indexed.sort { $0.entry.date < $1.entry.date }

    // Find entries with known values
    let knownIndices: [Int] = indexed.enumerated().compactMap { i, item in
        getValue(item.entry, column: column) != nil ? i : nil
    }

    guard !knownIndices.isEmpty else {
        return (entries, InterpolateResult(column: column, interpolated: 0, totalEntries: entries.count, knownValues: 0))
    }

    var interpolated = 0

    for i in 0..<indexed.count {
        if getValue(indexed[i].entry, column: column) != nil {
            continue
        }

        let entryTime = isoDateFormatter.date(from: indexed[i].entry.date)?.timeIntervalSince1970 ?? 0

        // Find surrounding known values
        var prevKnown: (time: Double, value: Double)?
        var nextKnown: (time: Double, value: Double)?

        for ki in knownIndices {
            let knownTime = isoDateFormatter.date(from: indexed[ki].entry.date)?.timeIntervalSince1970 ?? 0
            let knownValue = getValue(indexed[ki].entry, column: column) ?? 0

            if knownTime <= entryTime {
                prevKnown = (time: knownTime, value: knownValue)
            }
            if knownTime > entryTime && nextKnown == nil {
                nextKnown = (time: knownTime, value: knownValue)
                break
            }
        }

        var interpolatedValue: Double?
        if let prev = prevKnown, let next = nextKnown {
            let timeDiff = next.time - prev.time
            let valueDiff = next.value - prev.value
            let entryTimeDiff = entryTime - prev.time
            interpolatedValue = timeDiff > 0
                ? prev.value + (valueDiff * entryTimeDiff / timeDiff)
                : prev.value
        } else if let prev = prevKnown {
            interpolatedValue = prev.value
        } else if let next = nextKnown {
            interpolatedValue = next.value
        }

        if let val = interpolatedValue {
            let rounded = (val * 100).rounded() / 100
            setValue(&indexed[i].entry, column: column, value: rounded)
            interpolated += 1
        }
    }

    // Write results back to original positions by index
    var result = entries
    for item in indexed {
        if let val = getValue(item.entry, column: column) {
            setValue(&result[item.origIdx], column: column, value: val)
        }
    }

    return (result, InterpolateResult(column: column, interpolated: interpolated, totalEntries: entries.count, knownValues: knownIndices.count))
}

// MARK: - Column Accessors

private func getValue(_ entry: FundEntry, column: InterpolatableColumn) -> Double? {
    switch column {
    case .margin_available: return entry.margin_available
    case .margin_borrowed: return entry.margin_borrowed
    case .fund_size: return entry.fund_size
    case .value: return entry.value
    }
}

private func setValue(_ entry: inout FundEntry, column: InterpolatableColumn, value: Double) {
    switch column {
    case .margin_available: entry.margin_available = value
    case .margin_borrowed: entry.margin_borrowed = value
    case .fund_size: entry.fund_size = value
    case .value: entry.value = value
    }
}
