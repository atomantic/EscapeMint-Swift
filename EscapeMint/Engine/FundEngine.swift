import Foundation

// MARK: - Share Tracking & Liquidation Detection

func trackShares(trade: Trade, currentShares: Double) -> Double {
    guard let shares = trade.shares else { return currentShares }
    let sharesAbs = abs(shares)
    return currentShares + (trade.type == .sell ? -sharesAbs : sharesAbs)
}

func isFullLiquidation(shares: Double?, value: Double, amount: Double, sumShares: Double, totalBuys: Double, totalSells: Double) -> Bool {
    let hasShareTracking = shares != nil && (shares ?? 0) != 0
    let shareBasedLiq = hasShareTracking && abs(sumShares) < 0.0001
    let valueBasedLiq = value > 0 && value <= amount + 0.01
    let dollarBasedLiq = totalSells >= totalBuys
    return shareBasedLiq || valueBasedLiq || dollarBasedLiq
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
        if state.cashAvailableUsd < 0.01 {
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
    if buyAmount < 0.01 {
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
    return (gain / basis) * (365.0 / Double(days))
}

func computeCompoundAPY(_ returnPct: Double, _ days: Int) -> Double {
    guard days > 0 else { return 0 }
    return pow(1.0 + max(-0.99, returnPct), 365.0 / Double(days)) - 1.0
}

func computeProjectedAnnualReturn(_ currentValue: Double, _ realizedAPY: Double) -> Double {
    currentValue * realizedAPY
}

// MARK: - Derivatives Fund Metrics (matches web app fund-metrics.ts derivatives branch)

private func computeDerivativesFundMetrics(_ fund: FundData, asOfDate: String) -> (metrics: FundMetrics, state: FundState) {
    let config = fund.config
    let entries = fund.entries.sorted { $0.date < $1.date }
    var position = 0.0
    var marginBalance = 0.0
    var lastTradePrice = 0.0
    var cumFunding = 0.0
    var cumInterest = 0.0
    var cumRebates = 0.0
    var cumFees = 0.0
    var cumRealized = 0.0
    var totalBuyCost = 0.0
    var totalBuyContracts = 0.0

    // Cycle-based daysActive (derivatives: every SELL ends cycle)
    var cycleStartDate: String?
    var cumulativeActiveDays = 0.0

    for entry in entries {
        let action = entry.action
        let contracts = entry.contracts ?? 0
        let amount = entry.amount ?? 0
        let fee = entry.fee ?? 0
        let tradePrice = entry.price ?? 0

        switch action {
        case .DEPOSIT: marginBalance += abs(amount)
        case .WITHDRAW: marginBalance -= abs(amount)
        case .BUY:
            position += contracts
            totalBuyCost += abs(amount)
            totalBuyContracts += contracts
            let absFee = abs(fee)
            cumFees += absFee
            marginBalance -= absFee
            if tradePrice > 0 { lastTradePrice = tradePrice }
            if cycleStartDate == nil { cycleStartDate = entry.date }
        case .SELL:
            let sellContracts = min(contracts, totalBuyContracts)
            if sellContracts > 0 {
                let avgCostPerContract = totalBuyCost / totalBuyContracts
                let costOfSold = avgCostPerContract * sellContracts
                let pnl = abs(amount) - costOfSold
                cumRealized += pnl
                marginBalance += pnl
                totalBuyCost -= costOfSold
                totalBuyContracts -= sellContracts
            }
            position = max(0, position - contracts)
            let absFee = abs(fee)
            cumFees += absFee
            marginBalance -= absFee
            if tradePrice > 0 { lastTradePrice = tradePrice }
            // Every SELL ends a cycle for derivatives
            if let csd = cycleStartDate {
                cumulativeActiveDays += max(0, Double(daysBetween(csd, entry.date)))
                cycleStartDate = nil
            }
        case .FUNDING:
            cumFunding += amount; marginBalance += amount
        case .INTEREST:
            cumInterest += amount; marginBalance += amount
        case .REBATE:
            cumRebates += amount; marginBalance += amount
        case .FEE:
            let absFee = abs(amount); cumFees += absFee; marginBalance -= absFee
        default: break
        }
    }

    // Add current open cycle
    let endDate = entries.last?.date ?? asOfDate
    let currentCycleDays = cycleStartDate.map { max(0, Double(daysBetween($0, endDate))) } ?? 0
    let hasActiveHistory = cycleStartDate != nil || cumulativeActiveDays > 0
    let daysActive = hasActiveHistory
        ? max(1, Int(cumulativeActiveDays + currentCycleDays))
        : max(1, daysBetween(entries.first?.date ?? asOfDate, endDate))

    let effectiveMarginBalance = entries.last?.cash ?? marginBalance
    let avgCostPerContract = totalBuyContracts > 0 ? totalBuyCost / totalBuyContracts : 0
    let unrealized = entries.last?.unrealized_pnl ?? ((lastTradePrice - avgCostPerContract) * position)
    // Web app: realized = trade P&L only; funding/interest/rebates are separate
    let realized = cumRealized
    // Web app: liquidPnl includes funding/interest/rebates but NOT fees
    let liquidPL = realized + unrealized + cumFunding + cumInterest + cumRebates
    let equity = effectiveMarginBalance + unrealized
    let costBasis = totalBuyCost

    // APY from capital base — matches web app fund-metrics.ts derivatives branch
    let capitalBase = effectiveMarginBalance - liquidPL
    let denominator = capitalBase > 0 ? capitalBase : effectiveMarginBalance
    var realizedAPY = 0.0
    var liquidAPY = 0.0
    if daysActive > 0 && denominator > 0 {
        let realizedPlusFunding = realized + cumFunding + cumInterest + cumRebates
        realizedAPY = computeCompoundAPY(realizedPlusFunding / denominator, daysActive)
        liquidAPY = computeCompoundAPY(liquidPL / denominator, daysActive)
    }

    let isClosed = config.status == .closed
    let fundSize = isClosed ? 0 : effectiveMarginBalance
    let currentValue = isClosed ? 0 : equity
    let projAnnual = computeProjectedAnnualReturn(currentValue, realizedAPY)

    // TWFS: use marginBalance as the "deployed capital" basis
    let twfs = effectiveMarginBalance

    let metrics = FundMetrics(
        id: fund.id, platform: fund.platform, ticker: fund.ticker,
        status: config.status ?? .active, fundType: config.fund_type ?? .stock,
        category: config.category,
        fundSize: fundSize, currentValue: currentValue,
        startInput: costBasis, daysActive: daysActive,
        timeWeightedFundSize: twfs,
        realizedGains: realized, unrealizedGains: isClosed ? 0 : unrealized,
        realizedAPY: realizedAPY, liquidAPY: liquidAPY,
        projectedAnnualReturn: projAnnual,
        gainUsd: unrealized, gainPct: costBasis > 0 ? unrealized / costBasis : 0,
        totalDividends: 0, totalExpenses: cumFees, totalCashInterest: cumInterest
    )

    let state = FundState(
        cashAvailableUsd: effectiveMarginBalance - costBasis,
        expectedTargetUsd: equity,
        actualValueUsd: equity,
        startInputUsd: costBasis,
        gainUsd: liquidPL,
        gainPct: costBasis > 0 ? liquidPL / costBasis : 0,
        targetDiffUsd: 0,
        cashInterestUsd: cumInterest,
        realizedGainsUsd: realized
    )

    return (metrics, state)
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
            let hasShareTracking = entry.shares != nil && (entry.shares ?? 0) != 0
            let sharesLiquidated = hasShareTracking && abs(sumShares) < 0.0001
            let valueLiquidated = entry.value > 0 && entry.value <= amt + 0.01
            let isFullLiq = sharesLiquidated || valueLiquidated

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
        if abs(realized) >= 0.01 {
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

    // Build FundState directly from single-pass data (avoids redundant entry walks)
    let startInput = isCash ? cash : netInvested
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
        return funds.map { FundSummary($0, allFunds: funds) }
    }
    return zip(funds, zip(portfolio.funds, portfolio.states)).map { fund, pair in
        FundSummary(fund, metrics: pair.0, state: pair.1)
    }
}

/// Resolve the cash fund ID for a fund that doesn't manage its own cash.
func resolveCashFundId(config: FundConfig, platform: String) -> String {
    config.cash_fund ?? "\(platform)-cash"
}

func computePortfolioMetrics(_ funds: [FundData], asOfDate: String? = nil) -> PortfolioMetrics {
    let today = asOfDate ?? todayString()
    let computed: [(FundMetrics, FundState)] = funds.map { computeFundMetricsForFund($0, asOfDate: today) }
    return computePortfolioAggregate(funds, perFundMetrics: computed)
}

/// Aggregate pre-computed per-fund metrics into portfolio totals.
/// Split from `computePortfolioMetrics` so callers (FundDataStore) can cache
/// per-fund metrics and reuse them when only a subset of funds has changed.
/// `perFundMetrics` must be parallel with `funds`.
func computePortfolioAggregate(
    _ funds: [FundData],
    perFundMetrics: [(FundMetrics, FundState)]
) -> PortfolioMetrics {
    var computed = perFundMetrics

    // Resolve cash from platform cash funds for manage_cash=false funds
    let fundById = Dictionary(uniqueKeysWithValues: funds.map { ($0.id, $0) })
    for i in funds.indices {
        let fund = funds[i]
        if fund.config.manage_cash == false {
            let cashFundId = resolveCashFundId(config: fund.config, platform: fund.platform)
            if let cashFund = fundById[cashFundId],
               let latest = cashFund.entries.max(by: { $0.date < $1.date }) {
                computed[i].1.cashAvailableUsd = latest.cash ?? latest.value
            } else {
                computed[i].1.cashAvailableUsd = 0
            }
        }
    }

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

    // Compute portfolioDays: calendar span from earliest first entry to latest last entry
    // across ALL funds — matches web app aggregate route
    let allDates = funds.flatMap { $0.entries.map(\.date) }
    let portfolioDays: Int? = if let earliest = allDates.min(), let latest = allDates.max() {
        max(1, daysBetween(earliest, latest))
    } else {
        nil
    }

    // Dollar-weighted compound APY
    var totalDollarDays = 0.0
    var maxDaysActive = 0
    for fm in fundsWithShares {
        totalDollarDays += fm.timeWeightedFundSize * Double(fm.daysActive)
        maxDaysActive = max(maxDaysActive, fm.daysActive)
    }
    let effectivePortfolioDays = portfolioDays ?? maxDaysActive
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
            if let cashFund = fundById[cashFundId] {
                cashBalance = cashFund.entries.max(by: { $0.date < $1.date })?.cash
                    ?? cashFund.entries.max(by: { $0.date < $1.date })?.value ?? 0
            } else {
                cashBalance = 0
            }

            var effectiveAvailable = cashBalance
            if config.margin_enabled == true,
               let latestEntry = fund.entries.last,
               let marginAvail = latestEntry.margin_available, marginAvail > 0 {
                effectiveAvailable += marginAvail
            }

            if effectiveAvailable < 0.01 {
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

private func computeDerivativesEntryRows(entries: [FundEntry], config: FundConfig) -> [ComputedEntryRow] {
    let startDate = entries.first?.date ?? ""

    var position = 0.0
    var marginBalance = 0.0
    var lastTradePrice = 0.0
    var cumFunding = 0.0
    var cumInterest = 0.0
    var cumRebates = 0.0
    var cumFees = 0.0
    var cumRealized = 0.0
    var totalBuyCost = 0.0
    var totalBuyContracts = 0.0

    return entries.map { entry in
        let contracts = entry.contracts ?? 0
        let amount = entry.amount ?? 0
        let fee = entry.fee ?? 0
        let tradePrice = entry.price ?? 0

        switch entry.action {
        case .DEPOSIT: marginBalance += abs(amount)
        case .WITHDRAW: marginBalance -= abs(amount)
        case .BUY:
            position += contracts
            totalBuyCost += abs(amount)
            totalBuyContracts += contracts
            let absFee = abs(fee); cumFees += absFee; marginBalance -= absFee
            if tradePrice > 0 { lastTradePrice = tradePrice }
        case .SELL:
            let sellContracts = min(contracts, totalBuyContracts)
            if sellContracts > 0 {
                let avgCost = totalBuyCost / totalBuyContracts
                let costOfSold = avgCost * sellContracts
                let pnl = abs(amount) - costOfSold
                cumRealized += pnl; marginBalance += pnl
                totalBuyCost -= costOfSold; totalBuyContracts -= sellContracts
            }
            position = max(0, position - contracts)
            let absFee = abs(fee); cumFees += absFee; marginBalance -= absFee
            if tradePrice > 0 { lastTradePrice = tradePrice }
        case .FUNDING: cumFunding += amount; marginBalance += amount
        case .INTEREST: cumInterest += amount; marginBalance += amount
        case .REBATE: cumRebates += amount; marginBalance += amount
        case .FEE: let absFee = abs(amount); cumFees += absFee; marginBalance -= absFee
        default: break
        }

        let effectiveMB = entry.cash ?? marginBalance
        let avgCostPerContract = totalBuyContracts > 0 ? totalBuyCost / totalBuyContracts : 0
        let unrealized = entry.unrealized_pnl ?? ((lastTradePrice - avgCostPerContract) * position)
        // Match fund metrics: realized = trade P&L only
        let realized = cumRealized
        // Match fund metrics: liquidPL includes funding/interest/rebates but NOT fees
        let liquidPL = realized + unrealized + cumFunding + cumInterest + cumRebates

        // Compound APY (matches computeDerivativesFundMetrics)
        let days = Double(max(1, daysBetween(startDate, entry.date)))
        let capitalBase = effectiveMB - liquidPL
        let denom = capitalBase > 0 ? capitalBase : effectiveMB
        var realizedAPY = 0.0
        var liquidAPY = 0.0
        if days > 0 && denom > 0 {
            let realizedPlusFunding = realized + cumFunding + cumInterest + cumRebates
            realizedAPY = computeCompoundAPY(realizedPlusFunding / denom, Int(days))
            liquidAPY = computeCompoundAPY(liquidPL / denom, Int(days))
        }

        return ComputedEntryRow(
            extracted: 0, realized: realized, liquidPnl: liquidPL,
            realizedApy: realizedAPY, liquidApy: liquidAPY,
            isClosingEntry: false, invested: totalBuyCost, unrealized: unrealized,
            sumShares: position, sumExtracted: cumRealized,
            sumExpenses: cumFees, sumCashInterest: cumInterest, sumDividends: 0
        )
    }
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

