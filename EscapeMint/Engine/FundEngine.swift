import Foundation

// MARK: - Core Computations

func computeStartInput(trades: [Trade], asOfDate: String, config: FundConfig? = nil) -> Double {
    let filtered = trades.filter { $0.date <= asOfDate }
    let accumulate = config?.accumulate ?? true

    var totalBuys = 0.0
    var totalSells = 0.0
    var totalBuyAmount = 0.0

    for trade in filtered {
        if trade.type == .buy {
            totalBuys += trade.amountUsd
            totalBuyAmount += trade.amountUsd
        } else {
            totalSells += trade.amountUsd
        }
    }

    if accumulate {
        // In accumulate mode, sells don't reduce cost basis
        return totalBuys
    }

    // Harvest mode: sells reduce cost basis proportionally
    if totalSells >= totalBuys {
        return 0 // Fully liquidated
    }
    return totalBuys - totalSells
}

func computeExpectedTarget(config: FundConfig, trades: [Trade], asOfDate: String) -> Double {
    let targetApy = config.target_apy ?? 0
    if targetApy == 0 { return computeStartInput(trades: trades, asOfDate: asOfDate, config: config) }

    let filtered = trades.filter { $0.date <= asOfDate }
    var expectedGain = 0.0

    for trade in filtered {
        let days = daysBetween(trade.date, asOfDate)
        if days <= 0 { continue }
        let years = Double(days) / 365.0
        let gain = trade.amountUsd * (pow(1.0 + targetApy, years) - 1.0)
        if trade.type == .buy {
            expectedGain += gain
        } else {
            expectedGain -= gain
        }
    }

    let startInput = computeStartInput(trades: trades, asOfDate: asOfDate, config: config)
    return startInput + max(0, expectedGain)
}

func computeCashAvailable(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], asOfDate: String) -> Double {
    let fundSize = config.fund_size_usd ?? 0
    let startInput = computeStartInput(trades: trades, asOfDate: asOfDate, config: config)

    var cash = fundSize - startInput

    for cf in cashflows.filter({ $0.date <= asOfDate }) {
        if cf.type == .deposit { cash += cf.amountUsd }
        else { cash -= cf.amountUsd }
    }

    if config.dividend_reinvest == true {
        for d in dividends.filter({ $0.date <= asOfDate }) {
            cash += d.amountUsd
        }
    }

    if config.expense_from_fund == true {
        for e in expenses.filter({ $0.date <= asOfDate }) {
            cash -= e.amountUsd
        }
    }

    return cash
}

func computeCashInterest(config: FundConfig, trades: [Trade], cashflows: [CashFlow], asOfDate: String) -> Double {
    let cashApy = config.cash_apy ?? 0
    if cashApy == 0 { return 0 }

    let fundSize = config.fund_size_usd ?? 0
    var events: [(date: String, cashChange: Double)] = []
    events.append((date: getFundStartDate(trades.map { FundEntry(date: $0.date, value: 0) }), cashChange: fundSize))

    for trade in trades.filter({ $0.date <= asOfDate }) {
        if trade.type == .buy { events.append((trade.date, -trade.amountUsd)) }
        else { events.append((trade.date, trade.amountUsd)) }
    }
    for cf in cashflows.filter({ $0.date <= asOfDate }) {
        if cf.type == .deposit { events.append((cf.date, cf.amountUsd)) }
        else { events.append((cf.date, -cf.amountUsd)) }
    }

    events.sort { $0.date < $1.date }

    var totalInterest = 0.0
    var cashBalance = 0.0
    var lastDate = events.first?.date ?? asOfDate

    for event in events {
        let days = daysBetween(lastDate, event.date)
        if days > 0 && cashBalance > 0 {
            let years = Double(days) / 365.0
            totalInterest += cashBalance * (pow(1.0 + cashApy, years) - 1.0)
        }
        cashBalance += event.cashChange
        lastDate = event.date
    }

    // Accrue to asOfDate
    let remainingDays = daysBetween(lastDate, asOfDate)
    if remainingDays > 0 && cashBalance > 0 {
        let years = Double(remainingDays) / 365.0
        totalInterest += cashBalance * (pow(1.0 + cashApy, years) - 1.0)
    }

    return totalInterest
}

func computeRealizedGains(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], asOfDate: String) -> Double {
    let filtered = trades.filter { $0.date <= asOfDate }
    var totalBuys = 0.0
    var totalSells = 0.0

    for trade in filtered {
        if trade.type == .buy { totalBuys += trade.amountUsd }
        else { totalSells += trade.amountUsd }
    }

    var realized = 0.0
    if totalSells >= totalBuys {
        realized = totalSells - totalBuys
    }

    // Add interest
    realized += computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)

    // Add dividends
    for d in dividends.filter({ $0.date <= asOfDate }) {
        realized += d.amountUsd
    }

    // Subtract expenses
    if config.expense_from_fund == true {
        for e in expenses.filter({ $0.date <= asOfDate }) {
            realized -= e.amountUsd
        }
    }

    return realized
}

func computeFundState(config: FundConfig, trades: [Trade], cashflows: [CashFlow], dividends: [Dividend], expenses: [Expense], actualValue: Double, asOfDate: String) -> FundState {
    // Cash funds: state IS the cash balance
    if isCashFund(config.fund_type) {
        let interest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
        return FundState(
            cashAvailableUsd: actualValue,
            expectedTargetUsd: actualValue,
            actualValueUsd: actualValue,
            startInputUsd: actualValue,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: 0,
            cashInterestUsd: interest,
            realizedGainsUsd: interest
        )
    }

    let startInput = computeStartInput(trades: trades, asOfDate: asOfDate, config: config)
    let expectedTarget = computeExpectedTarget(config: config, trades: trades, asOfDate: asOfDate)
    let cashAvailable = computeCashAvailable(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, asOfDate: asOfDate)
    let cashInterest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
    let realizedGains = computeRealizedGains(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, asOfDate: asOfDate)

    let gainUsd = actualValue - startInput
    let gainPct = startInput > 0 ? gainUsd / startInput : 0
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

// MARK: - Recommendation

func computeLimit(config: FundConfig, state: FundState) -> Double {
    let minUsd = config.input_min_usd ?? 0
    let midUsd = config.input_mid_usd ?? 0
    let maxUsd = config.input_max_usd ?? 0
    let maxAtPct = config.max_at_pct ?? -0.25

    if state.startInputUsd == 0 { return minUsd }
    if state.gainPct < 0 && state.gainPct <= maxAtPct { return maxUsd }
    if state.gainPct < 0 { return midUsd }
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

    // SELL: above target AND in profit
    if state.targetDiffUsd > 0 && state.gainUsd > 0 {
        let accumulate = config.accumulate ?? true
        let sellAmount = accumulate ? limit : state.actualValueUsd
        let reasoning = accumulate
            ? "Above target by \(formatCurrency(state.targetDiffUsd)) and in profit. Sell \(formatCurrency(limit)) to capture gains."
            : "Above target by \(formatCurrency(state.targetDiffUsd)). Harvest entire position of \(formatCurrency(state.actualValueUsd))."
        return Recommendation(action: .SELL, amount: sellAmount, reasoning: reasoning)
    }

    // BUY: below target or no investment yet
    if state.cashAvailableUsd <= 0 {
        return Recommendation(action: .HOLD, amount: 0, reasoning: "No cash available for purchase.")
    }

    let buyAmount = min(limit, state.cashAvailableUsd)
    let reasoning: String
    if state.startInputUsd == 0 {
        reasoning = "No position yet. Initial buy of \(formatCurrency(buyAmount))."
    } else if state.gainPct < (config.max_at_pct ?? -0.25) {
        reasoning = "Down \(formatPercent(state.gainPct)) (past max threshold). Max DCA of \(formatCurrency(buyAmount))."
    } else if state.gainPct < 0 {
        reasoning = "Down \(formatPercent(state.gainPct)). Mid DCA of \(formatCurrency(buyAmount))."
    } else {
        reasoning = "At cost or above but below target. Min DCA of \(formatCurrency(buyAmount))."
    }

    return Recommendation(action: .BUY, amount: buyAmount, reasoning: reasoning)
}

// MARK: - Aggregate

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
        lastDate = trade.date
    }

    let remaining = daysBetween(lastDate, asOfDate)
    if remaining > 0 {
        weightedSum += cumulativeInvestment * Double(remaining)
    }

    return weightedSum / Double(totalDays)
}

func computeRealizedAPY(_ realizedGains: Double, _ basis: Double, _ days: Int) -> Double {
    if basis <= 0 || days <= 0 { return 0 }
    let returnPct = realizedGains / basis
    return pow(1.0 + returnPct, 365.0 / Double(days)) - 1.0
}

// MARK: - Formatters

func formatCurrency(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0"
}

func formatPercent(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .percent
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "0%"
}
