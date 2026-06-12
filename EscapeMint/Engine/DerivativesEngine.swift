import Foundation

// MARK: - Derivatives Fund Metrics (matches web app fund-metrics.ts derivatives branch)

func computeDerivativesFundMetrics(_ fund: FundData, asOfDate: String) -> (metrics: FundMetrics, state: FundState) {
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
        totalDividends: 0, totalExpenses: cumFees, totalCashInterest: cumInterest,
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
        cashInterestUsd: cumInterest,
        realizedGainsUsd: realized
    )

    return (metrics, state)
}

// MARK: - Derivatives Per-Entry Computed Data

func computeDerivativesEntryRows(entries: [FundEntry], config: FundConfig) -> [ComputedEntryRow] {
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
