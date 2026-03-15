import Foundation

// MARK: - Share Tracking & Liquidation Detection

func trackShares(trade: Trade, currentShares: Double) -> Double {
    guard let shares = trade.shares else { return currentShares }
    let sharesAbs = abs(shares)
    return currentShares + (trade.type == .sell ? -sharesAbs : sharesAbs)
}

func detectFullLiquidation(trade: Trade, sumShares: Double, totalBuys: Double, totalSells: Double) -> Bool {
    let hasShareTracking = trade.shares != nil && trade.shares != 0
    let shareBasedLiquidation = hasShareTracking && abs(sumShares) < 0.0001
    // Only use value-based liquidation when value > 0 (value=0 means "unknown")
    let valueBasedLiquidation = trade.value != nil && (trade.value ?? 0) > 0 && (trade.value ?? 0) <= trade.amountUsd + 0.01
    let dollarBasedLiquidation = totalSells >= totalBuys
    return shareBasedLiquidation || valueBasedLiquidation || dollarBasedLiquidation
}

// MARK: - Core Computations

func computeStartInput(trades: [Trade], asOfDate: String, config: FundConfig? = nil) -> Double {
    let isAccumulateMode = config?.accumulate ?? true
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
            let gain = trade.amountUsd * (pow(1.0 + targetApy, Double(tradeDays) / 365.0) - 1.0)
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
                let isAccumulateMode = config.accumulate ?? true
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
    let fundSize = config.fund_size_usd ?? 0
    let startInput = computeStartInput(trades: trades, asOfDate: asOfDate, config: config)
    var cash = fundSize - startInput

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

    let fundSize = config.fund_size_usd ?? 0
    var events: [(date: String, sign: Double, amount: Double)] = []

    for trade in trades {
        events.append((trade.date, trade.type == .buy ? -1 : 1, trade.amountUsd))
    }
    for cf in cashflows {
        events.append((cf.date, cf.type == .deposit ? 1 : -1, cf.amountUsd))
    }

    events.sort { $0.date < $1.date }

    var totalInterest = 0.0
    var currentCash = fundSize
    var lastDate = events.first?.date ?? asOfDate

    for event in events {
        if daysBetween(event.date, asOfDate) < 0 { continue }
        if daysBetween(lastDate, event.date) < 0 { continue }

        let periodDays = daysBetween(lastDate, event.date)
        if periodDays > 0 && currentCash > 0 {
            totalInterest += currentCash * (pow(1.0 + cashApy, Double(periodDays) / 365.0) - 1.0)
        }

        currentCash += event.sign * event.amount
        currentCash = max(0, currentCash)
        lastDate = event.date
    }

    let finalDays = daysBetween(lastDate, asOfDate)
    if finalDays > 0 && currentCash > 0 {
        totalInterest += currentCash * (pow(1.0 + cashApy, Double(finalDays) / 365.0) - 1.0)
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
    let clampedReturn = max(-0.99, returnPct)
    let apy = durationDays > 3 ? pow(1.0 + clampedReturn, 365.0 / Double(durationDays)) - 1.0 : clampedReturn

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
    return (gain / basis) * (365.0 / Double(days))
}

func computeProjectedAnnualReturn(_ currentValue: Double, _ realizedAPY: Double) -> Double {
    currentValue * realizedAPY
}

// MARK: - Full Fund Metrics

func computeFundMetricsForFund(_ fund: FundData, asOfDate: String) -> (metrics: FundMetrics, state: FundState) {
    let config = fund.config
    let trades = entriesToTrades(fund.entries)
    let cashflows = entriesToCashFlows(fund.entries)
    let dividends = entriesToDividends(fund.entries)
    let expenses = entriesToExpenses(fund.entries)
    let value = getLatestValue(fund.entries)
    let isCash = isCashFund(config.fund_type)

    let candidateDates = [
        cashflows.isEmpty ? nil : getFundStartDate(cashflows.map { FundEntry(date: $0.date, value: 0) }),
        trades.isEmpty ? nil : getFundStartDate(trades.map { FundEntry(date: $0.date, value: 0) }),
        fund.entries.isEmpty ? nil : getFundStartDate(fund.entries)
    ].compactMap { $0 }
    let startDate = candidateDates.min() ?? asOfDate
    let daysActive = max(1, daysBetween(startDate, asOfDate))

    let state = computeFundState(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: value, asOfDate: asOfDate)

    let twfs = isCash
        ? computeCashFundTimeWeightedSize(cashFlows: cashflows, startDate: startDate, asOfDate: asOfDate)
        : computeTimeWeightedFundSize(trades: trades, startDate: startDate, asOfDate: asOfDate)

    let realizedGains = state.realizedGainsUsd
    let realizedAPY = computeLinearAPY(realizedGains, twfs, daysActive)
    let projectedAnnualReturn = computeProjectedAnnualReturn(value, realizedAPY)
    let unrealizedGains = isCash ? 0 : state.gainUsd
    let liquidGain = unrealizedGains + realizedGains
    let liquidAPY = computeLinearAPY(liquidGain, twfs, daysActive)
    let gainUsd = isCash ? realizedGains : unrealizedGains

    let metrics = FundMetrics(
        id: fund.id,
        platform: fund.platform,
        ticker: fund.ticker,
        status: config.status ?? .active,
        fundType: config.fund_type ?? .stock,
        category: config.category,
        fundSize: config.fund_size_usd ?? 0,
        currentValue: value,
        startInput: state.startInputUsd,
        daysActive: daysActive,
        timeWeightedFundSize: twfs,
        realizedGains: realizedGains,
        unrealizedGains: unrealizedGains,
        realizedAPY: realizedAPY,
        liquidAPY: liquidAPY,
        projectedAnnualReturn: projectedAnnualReturn,
        gainUsd: gainUsd,
        gainPct: state.gainPct,
        fundShares: 0,
        fundSharesPct: 0
    )
    return (metrics, state)
}

// MARK: - Portfolio Aggregate

/// Build FundSummary array from pre-computed portfolio metrics, avoiding double computation.
/// Uses the metrics and states already computed by computePortfolioMetrics.
func computeSummariesFromPortfolio(funds: [FundData], portfolio: PortfolioMetrics) -> [FundSummary] {
    guard funds.count == portfolio.funds.count, funds.count == portfolio.states.count else {
        // Fallback if sizes mismatch
        return funds.map { FundSummary($0) }
    }
    return zip(funds, zip(portfolio.funds, portfolio.states)).map { fund, pair in
        FundSummary(fund, metrics: pair.0, state: pair.1)
    }
}

func computePortfolioMetrics(_ funds: [FundData], asOfDate: String? = nil) -> PortfolioMetrics {
    let today = asOfDate ?? todayString()
    let computed: [(FundMetrics, FundState)] = funds.map { computeFundMetricsForFund($0, asOfDate: today) }
    let fundMetrics = computed.map(\.0)

    var totalFundSize = 0.0
    var totalValue = 0.0
    var totalStartInput = 0.0
    var totalTWFS = 0.0
    var totalDaysActive = 0
    var totalRealizedGains = 0.0
    var totalUnrealizedGains = 0.0
    var activeFunds = 0
    var closedFunds = 0
    var cashBalance = 0.0
    var totalInterest = 0.0

    for (fm, state) in computed {
        totalFundSize += fm.fundSize
        totalValue += fm.currentValue
        totalStartInput += fm.startInput
        totalTWFS += fm.timeWeightedFundSize
        totalDaysActive += fm.daysActive
        totalRealizedGains += fm.realizedGains
        totalUnrealizedGains += fm.unrealizedGains
        totalInterest += state.cashInterestUsd

        if fm.status == .closed { closedFunds += 1 }
        else { activeFunds += 1 }

        if isCashFund(fm.fundType) && fm.status != .closed {
            cashBalance += fm.currentValue
        }
    }

    // Fund shares calculation (single pass)
    let dollarsPerDay = totalTWFS > 0 && totalDaysActive > 0 ? totalTWFS / Double(totalDaysActive) : 0
    var totalFundShares = 0.0
    var fundsWithShares = fundMetrics.map { fm -> FundMetrics in
        var updated = fm
        updated.fundShares = dollarsPerDay > 0 && fm.daysActive > 0
            ? (fm.timeWeightedFundSize / dollarsPerDay) * Double(fm.daysActive)
            : 0
        totalFundShares += updated.fundShares
        return updated
    }

    for i in fundsWithShares.indices {
        fundsWithShares[i].fundSharesPct = totalFundShares > 0 ? fundsWithShares[i].fundShares / totalFundShares : 0
    }

    // Dollar-weighted compound APY
    var totalDollarDays = 0.0
    var maxDaysActive = 0
    for fm in fundsWithShares {
        totalDollarDays += fm.timeWeightedFundSize * Double(fm.daysActive)
        maxDaysActive = max(maxDaysActive, fm.daysActive)
    }
    let effectivePortfolioDays = maxDaysActive
    let avgCapital = effectivePortfolioDays > 0 ? totalDollarDays / Double(effectivePortfolioDays) : 0

    var weightedRealizedAPY = 0.0
    if avgCapital > 0 && effectivePortfolioDays > 0 {
        let totalReturn = max(-0.99, totalRealizedGains / avgCapital)
        weightedRealizedAPY = pow(1.0 + totalReturn, 365.0 / Double(effectivePortfolioDays)) - 1.0
    }

    let totalGainUsd = totalRealizedGains + totalUnrealizedGains
    var aggregateLiquidAPY = 0.0
    if avgCapital > 0 && effectivePortfolioDays > 0 {
        let liquidReturn = max(-0.99, totalGainUsd / avgCapital)
        aggregateLiquidAPY = pow(1.0 + liquidReturn, 365.0 / Double(effectivePortfolioDays)) - 1.0
    }

    let totalActiveValue = fundsWithShares
        .filter { $0.status != .closed && $0.currentValue > 0 }
        .reduce(0.0) { $0 + $1.currentValue }
    let projectedAnnualReturn = totalActiveValue * weightedRealizedAPY

    let totalGainPct = totalStartInput > 0 ? (totalValue / totalStartInput - 1.0) : 0

    return PortfolioMetrics(
        totalFundSize: totalFundSize,
        totalValue: totalValue,
        totalStartInput: totalStartInput,
        totalTimeWeightedFundSize: totalTWFS,
        totalDaysActive: totalDaysActive,
        totalRealizedGains: totalRealizedGains,
        totalUnrealizedGains: totalUnrealizedGains,
        realizedAPY: weightedRealizedAPY,
        liquidAPY: aggregateLiquidAPY,
        projectedAnnualReturn: projectedAnnualReturn,
        totalGainUsd: totalGainUsd,
        totalGainPct: totalGainPct,
        activeFunds: activeFunds,
        closedFunds: closedFunds,
        portfolioDays: effectivePortfolioDays,
        cashBalance: cashBalance,
        totalInterest: totalInterest,
        funds: fundsWithShares,
        states: computed.map(\.1)
    )
}

// MARK: - Actionable Funds (Attention Alerts)

struct ActionableFund: Identifiable {
    let id: String
    let fund: FundData
    let daysOverdue: Int      // positive = overdue, 0 = due today, negative = upcoming
    let intervalDays: Int

    var urgency: Urgency {
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
    let urgencyThresholdDays = 7

    return funds.compactMap { fund -> ActionableFund? in
        let config = fund.config
        // Skip closed, cash, derivatives, and funds without intervals
        guard config.status != .closed,
              !isCashFund(config.fund_type),
              config.fund_type != .derivatives,
              let intervalDays = config.interval_days,
              intervalDays > 0 else { return nil }

        // Find last entry date
        guard let lastEntry = fund.entries.last else {
            // No entries = overdue (fund was created but never acted on)
            return ActionableFund(id: fund.id, fund: fund, daysOverdue: intervalDays, intervalDays: intervalDays)
        }

        let daysSinceLastEntry = daysBetween(lastEntry.date, today)
        let daysOverdue = daysSinceLastEntry - intervalDays

        // Only show if within urgency threshold (upcoming by ≤7 days, or overdue)
        guard daysOverdue >= -urgencyThresholdDays else { return nil }

        return ActionableFund(id: fund.id, fund: fund, daysOverdue: daysOverdue, intervalDays: intervalDays)
    }
    .sorted { $0.daysOverdue > $1.daysOverdue } // Most overdue first
}

// MARK: - Formatters (cached)

private let currencyFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    return f
}()

private let percentFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

func formatCurrency(_ value: Double) -> String {
    currencyFormatter.maximumFractionDigits = abs(value) >= 1000 ? 0 : 2
    return currencyFormatter.string(from: NSNumber(value: value)) ?? "$0"
}

func formatPercent(_ value: Double) -> String {
    percentFormatter.string(from: NSNumber(value: value)) ?? "0%"
}

func formatCurrencyCompact(_ value: Double) -> String {
    let absValue = abs(value)
    let sign = value < 0 ? "-" : ""
    if absValue >= 1_000_000 {
        return "\(sign)$\(String(format: "%.1f", absValue / 1_000_000))M"
    } else if absValue >= 1000 {
        return "\(sign)$\(String(format: "%.1f", absValue / 1000))K"
    } else {
        return "\(sign)$\(String(format: "%.0f", absValue))"
    }
}

func formatPercentSigned(_ value: Double) -> String {
    let pct = value * 100
    let sign = pct >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", pct))%"
}
