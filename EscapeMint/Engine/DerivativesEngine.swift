import Foundation

// MARK: - Shared Derivatives Entry Accumulator

/// Running position/PnL state shared by every derivatives entry walk (fund metrics,
/// per-entry rows, and chart data). `apply(_:)` advances the accumulator over a single
/// entry, applying the one canonical action switch so a new action type or rule change
/// lives in exactly one place.
struct DerivativesAccumulator {
    var position = 0.0
    var marginBalance = 0.0
    var lastTradePrice = 0.0 // per-contract price for unrealized estimation
    var cumFunding = 0.0
    var cumInterest = 0.0
    var cumRebates = 0.0
    var cumFees = 0.0
    var cumRealized = 0.0
    var totalBuyCost = 0.0
    var totalBuyContracts = 0.0

    /// Advance the accumulator over one entry. Pure with respect to external state —
    /// it only mutates `self`.
    mutating func apply(_ entry: FundEntry) {
        let contracts = entry.contracts ?? 0
        let amount = entry.amount ?? 0
        let fee = entry.fee ?? 0
        let tradePrice = entry.price ?? 0

        switch entry.action {
        case .DEPOSIT:
            marginBalance += abs(amount)
        case .WITHDRAW:
            marginBalance -= abs(amount)
        case .BUY:
            position += contracts
            totalBuyCost += abs(amount)
            totalBuyContracts += contracts
            let absFee = abs(fee)
            cumFees += absFee
            marginBalance -= absFee
            if tradePrice > 0 { lastTradePrice = tradePrice }
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
        case .FUNDING:
            cumFunding += amount
            marginBalance += amount
        case .INTEREST:
            cumInterest += amount
            marginBalance += amount
        case .REBATE:
            cumRebates += amount
            marginBalance += amount
        case .FEE:
            let absFee = abs(amount)
            cumFees += absFee
            marginBalance -= absFee
        default:
            break
        }
    }

    /// Volume-weighted average cost per contract of the currently open position.
    var avgCostPerContract: Double {
        totalBuyContracts > 0 ? totalBuyCost / totalBuyContracts : 0
    }
}

// MARK: - Derivatives Fund Metrics (matches web app fund-metrics.ts derivatives branch)

func computeDerivativesFundMetrics(_ fund: FundData, asOfDate: String) -> (metrics: FundMetrics, state: FundState) {
    let config = fund.config
    let entries = fund.entries.sorted { $0.date < $1.date }
    var acc = DerivativesAccumulator()

    // Cycle-based daysActive (derivatives: every SELL ends cycle)
    var cycleStartDate: String?
    var cumulativeActiveDays = 0.0

    for entry in entries {
        acc.apply(entry)

        // Cycle bookkeeping: a BUY opens a cycle, every SELL closes it.
        switch entry.action {
        case .BUY:
            if cycleStartDate == nil { cycleStartDate = entry.date }
        case .SELL:
            if let csd = cycleStartDate {
                cumulativeActiveDays += max(0, Double(daysBetween(csd, entry.date)))
                cycleStartDate = nil
            }
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

    let effectiveMarginBalance = entries.last?.cash ?? acc.marginBalance
    let unrealized = entries.last?.unrealized_pnl ?? ((acc.lastTradePrice - acc.avgCostPerContract) * acc.position)
    // Web app: realized = trade P&L only; funding/interest/rebates are separate
    let realized = acc.cumRealized
    // Web app: liquidPnl includes funding/interest/rebates but NOT fees
    let liquidPL = realized + unrealized + acc.cumFunding + acc.cumInterest + acc.cumRebates
    let equity = effectiveMarginBalance + unrealized
    let costBasis = acc.totalBuyCost

    // APY from capital base — matches web app fund-metrics.ts derivatives branch
    let capitalBase = effectiveMarginBalance - liquidPL
    let denominator = capitalBase > 0 ? capitalBase : effectiveMarginBalance
    var realizedAPY = 0.0
    var liquidAPY = 0.0
    if daysActive > 0 && denominator > 0 {
        let realizedPlusFunding = realized + acc.cumFunding + acc.cumInterest + acc.cumRebates
        realizedAPY = computeCompoundAPY(realizedPlusFunding / denominator, daysActive)
        liquidAPY = computeCompoundAPY(liquidPL / denominator, daysActive)
    }

    let isClosed = config.status == .closed
    let freeCollateral = effectiveMarginBalance - costBasis
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
        totalDividends: 0, totalExpenses: acc.cumFees, totalCashInterest: acc.cumInterest,
        cash: isClosed ? 0 : freeCollateral
    )

    let state = FundState(
        cashAvailableUsd: freeCollateral,
        expectedTargetUsd: equity,
        actualValueUsd: equity,
        startInputUsd: costBasis,
        gainUsd: liquidPL,
        gainPct: costBasis > 0 ? liquidPL / costBasis : 0,
        targetDiffUsd: 0,
        cashInterestUsd: acc.cumInterest,
        realizedGainsUsd: realized
    )

    return (metrics, state)
}

// MARK: - Derivatives Per-Entry Computed Data

func computeDerivativesEntryRows(entries: [FundEntry], config: FundConfig) -> [ComputedEntryRow] {
    let startDate = entries.first?.date ?? ""
    var acc = DerivativesAccumulator()

    return entries.map { entry in
        acc.apply(entry)

        let effectiveMB = entry.cash ?? acc.marginBalance
        let unrealized = entry.unrealized_pnl ?? ((acc.lastTradePrice - acc.avgCostPerContract) * acc.position)
        // Match fund metrics: realized = trade P&L only
        let realized = acc.cumRealized
        // Match fund metrics: liquidPL includes funding/interest/rebates but NOT fees
        let liquidPL = realized + unrealized + acc.cumFunding + acc.cumInterest + acc.cumRebates

        // Compound APY (matches computeDerivativesFundMetrics)
        let days = Double(max(1, daysBetween(startDate, entry.date)))
        let capitalBase = effectiveMB - liquidPL
        let denom = capitalBase > 0 ? capitalBase : effectiveMB
        var realizedAPY = 0.0
        var liquidAPY = 0.0
        if days > 0 && denom > 0 {
            let realizedPlusFunding = realized + acc.cumFunding + acc.cumInterest + acc.cumRebates
            realizedAPY = computeCompoundAPY(realizedPlusFunding / denom, Int(days))
            liquidAPY = computeCompoundAPY(liquidPL / denom, Int(days))
        }

        return ComputedEntryRow(
            extracted: 0, realized: realized, liquidPnl: liquidPL,
            realizedApy: realizedAPY, liquidApy: liquidAPY,
            isClosingEntry: false, invested: acc.totalBuyCost, unrealized: unrealized,
            sumShares: acc.position, sumExtracted: acc.cumRealized,
            sumExpenses: acc.cumFees, sumCashInterest: acc.cumInterest, sumDividends: 0
        )
    }
}
