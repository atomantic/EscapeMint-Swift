import Foundation

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

    // Compute portfolioDays without flattening every entry date into a temporary
    // array. This runs on each recompute, so keeping it as a streaming scan avoids
    // allocation churn for large histories.
    var earliestDate: String?
    var latestDate: String?
    for fund in funds {
        for entry in fund.entries {
            if earliestDate == nil || entry.date < earliestDate! { earliestDate = entry.date }
            if latestDate == nil || entry.date > latestDate! { latestDate = entry.date }
        }
    }
    let portfolioDays: Int? = if let earliest = earliestDate, let latest = latestDate {
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
        let totalReturn = max(FundMath.minReturnRate, totalRealizedGains / avgCapital)
        weightedRealizedAPY = pow(1.0 + totalReturn, FundMath.daysPerYear / Double(effectivePortfolioDays)) - 1.0
    }

    let totalGainUsd = totalRealizedGains + totalUnrealizedGains
    var aggregateLiquidAPY = 0.0
    if avgCapital > 0 && effectivePortfolioDays > 0 {
        let liquidReturn = max(FundMath.minReturnRate, totalGainUsd / avgCapital)
        aggregateLiquidAPY = pow(1.0 + liquidReturn, FundMath.daysPerYear / Double(effectivePortfolioDays)) - 1.0
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
