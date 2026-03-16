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
        let buyAmount = hasCashPool ? min(limit, state.cashAvailableUsd) : limit
        return Recommendation(action: .BUY, amount: buyAmount,
                              reasoning: "Initial DCA purchase of \(formatCurrency(buyAmount)).")
    }

    // SELL: above target by more than min_profit AND in profit
    let minProfit = config.min_profit_usd ?? 0
    if state.targetDiffUsd > minProfit && state.gainUsd > 0 {
        let accumulate = config.accumulate == true
        let sellAmount = accumulate ? limit : state.actualValueUsd
        let reasoning = accumulate
            ? "Above target by \(formatCurrency(state.targetDiffUsd)) (> \(formatCurrency(minProfit)) threshold). Sell \(formatCurrency(sellAmount))."
            : "Above target by \(formatCurrency(state.targetDiffUsd)) (> \(formatCurrency(minProfit)) threshold). Harvest entire position of \(formatCurrency(state.actualValueUsd))."
        return Recommendation(action: .SELL, amount: sellAmount, reasoning: reasoning)
    }

    // BUY: below or at target
    let buyAmount = hasCashPool ? min(limit, state.cashAvailableUsd) : limit

    // No cash available — HOLD
    if (hasCashPool && buyAmount < 0.01) || (!hasCashPool && state.cashAvailableUsd < 0.01) {
        return Recommendation(action: .HOLD, amount: 0, reasoning: "No cash available for DCA. Holding position.")
    }

    let reasoning: String
    if state.gainUsd < 0 && state.gainPct < (config.max_at_pct ?? -0.25) {
        reasoning = "Significant loss (\(formatPercent(state.gainPct))). DCA max amount: \(formatCurrency(limit))."
    } else if state.gainUsd < 0 {
        reasoning = "Below cost basis (\(formatPercent(state.gainPct)) loss). DCA mid amount: \(formatCurrency(limit))."
    } else {
        reasoning = "On track or above cost. DCA min amount: \(formatCurrency(limit))."
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

// MARK: - Full Fund Metrics (single-pass, matches web app fund-metrics.ts)

func computeFundMetricsForFund(_ fund: FundData, asOfDate: String) -> (metrics: FundMetrics, state: FundState) {
    let config = fund.config
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
    let endDate = latestEntry?.date ?? asOfDate
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
        let cashVal = latestEntry?.cash ?? latestEntry?.fund_size ?? latestEntry?.value ?? 0
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
            computedFundSize = isAccumulate
                ? (latestEntry?.fund_size ?? netInvested)
                : netInvested
        } else {
            computedFundSize = latestEntry?.fund_size ?? config.fund_size_usd ?? 0
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
            let returnPct = realized / denominator
            let clampedPct = max(-0.99, returnPct)
            realizedAPY = pow(1.0 + clampedPct, 365.0 / Double(daysActive)) - 1.0
            liquidAPY = realizedAPY
        }
    } else {
        let twap = Double(daysActive) > 0 ? twapNumerator / Double(daysActive) : 0
        let denominator = twap > 0 ? twap : (costBasis > 0 ? costBasis : 1)
        if denominator > 0 {
            let realizedReturnPct = realized / denominator
            let clampedRealizedPct = max(-0.99, realizedReturnPct)
            realizedAPY = pow(1.0 + clampedRealizedPct, 365.0 / Double(daysActive)) - 1.0

            let liquidReturnPct = liquidPnl / denominator
            let clampedLiquidPct = max(-0.99, liquidReturnPct)
            liquidAPY = pow(1.0 + clampedLiquidPct, 365.0 / Double(daysActive)) - 1.0
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


    return funds.compactMap { fund -> ActionableFund? in
        let config = fund.config
        // Skip closed, cash, derivatives, and funds without intervals
        guard config.status != .closed,
              !isCashFund(config.fund_type),
              config.fund_type != .derivatives,
              let intervalDays = config.interval_days,
              intervalDays > 0 else { return nil }

        // Find last entry date — skip funds with no entries (matches web app)
        guard let lastEntry = fund.entries.last else {
            return nil
        }

        let daysSinceLastEntry = daysBetween(lastEntry.date, today)
        let daysOverdue = daysSinceLastEntry - intervalDays

        // Only show if due today or overdue
        guard daysOverdue >= 0 else { return nil }

        return ActionableFund(id: fund.id, fund: fund, daysOverdue: daysOverdue, intervalDays: intervalDays)
    }
    .sorted { $0.daysOverdue > $1.daysOverdue } // Most overdue first
}

// MARK: - Per-Entry Computed Data (for entries table columns)

struct ComputedEntryRow {
    let extracted: Double
    let realized: Double
    let liquidPnl: Double
    let realizedApy: Double
    let liquidApy: Double
    let isClosingEntry: Bool
}

func computeEntryRows(entries: [FundEntry], config: FundConfig) -> [ComputedEntryRow] {
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
    var activeDays = 0
    var lastDate = entries.first?.date ?? ""

    return entries.map { entry in
        let daysSinceLast = lastDate.isEmpty ? 0 : max(0, daysBetween(lastDate, entry.date))

        // Accumulate TWAP using cost basis BEFORE this entry's action
        if daysSinceLast > 0 && costBasis > 0 {
            twapNumerator += costBasis * Double(daysSinceLast)
        }
        activeDays += daysSinceLast

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
                twapNumerator = 0
                activeDays = 0
            } else if isAccumulate {
                entryExtracted = amt
                sumExtracted += entryExtracted
                totalSells = 0
            } else {
                let hasShareTracking = entry.shares != nil && (entry.shares ?? 0) != 0
                if hasShareTracking && totalBuys > 0 {
                    let sharesBeforeSell = sumShares + abs(entry.shares ?? 0)
                    let sellFraction = sharesBeforeSell > 0 ? abs(entry.shares ?? 0) / sharesBeforeSell : 1.0
                    let costBasisReturned = costBasis * sellFraction
                    entryExtracted = max(0, amt - costBasisReturned)
                    sumExtracted += entryExtracted
                    costBasis -= costBasisReturned
                    totalBuys -= costBasisReturned
                    totalSells = 0
                }
            }
        }

        let realized = sumExtracted + sumDividends + sumCashInterest - sumExpenses
        let unrealized = entry.value - costBasis
        let liquidPnl = unrealized + realized

        // Compound APY (matches web app per-entry formula)
        let twap = activeDays > 0 ? twapNumerator / Double(activeDays) : 0
        let basis = twap > 0 ? twap : costBasis

        var realizedApy = 0.0
        var liquidApy = 0.0

        if activeDays > 0 && basis > 0 {
            let rPct = max(-0.99, realized / basis)
            realizedApy = pow(1.0 + rPct, 365.0 / Double(activeDays)) - 1.0
            let lPct = max(-0.99, liquidPnl / basis)
            liquidApy = pow(1.0 + lPct, 365.0 / Double(activeDays)) - 1.0
        }

        lastDate = entry.date

        return ComputedEntryRow(
            extracted: entryExtracted,
            realized: realized,
            liquidPnl: liquidPnl,
            realizedApy: realizedApy,
            liquidApy: liquidApy,
            isClosingEntry: isClosing
        )
    }
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
