import Foundation

// MARK: - DateIdentifiable Protocol

/// Common protocol for chart series points keyed by an ISO date string.
/// Pure data abstraction (no SwiftUI dependency) so chart computations live in Engine.
protocol DateIdentifiable: Identifiable {
    var date: String { get }
    var dateValue: Date { get }
}

extension DateIdentifiable {
    var dateValue: Date {
        isoDateFormatter.date(from: date) ?? .distantPast
    }
}

// MARK: - Sampling

/// Downsample a series to at most `maxPoints` evenly spaced points, always keeping the last.
func sampleArray<T>(_ items: [T], maxPoints: Int = 60) -> [T] {
    let step = max(1, items.count / maxPoints)
    return items.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == items.count - 1 }
        .map(\.element)
}

private func sortedByDateStable(_ entries: [FundEntry]) -> [FundEntry] {
    entries.enumerated()
        .sorted {
            if $0.element.date == $1.element.date { return $0.offset < $1.offset }
            return $0.element.date < $1.element.date
        }
        .map(\.element)
}

/// Collapse same-date items to the last one (end-of-day snapshot). Input must be
/// date-sorted: only adjacent duplicates collapse. Charts need at most one point
/// per date — repeated x-values from intra-day entries degenerate area fills into
/// self-intersecting polygons and duplicate ForEach ids.
private func latestPerDate<T>(_ items: [T], date: (T) -> String) -> [T] {
    var daily: [T] = []
    daily.reserveCapacity(items.count)

    for item in items {
        if let last = daily.last, date(last) == date(item) {
            daily[daily.count - 1] = item
        } else {
            daily.append(item)
        }
    }

    return daily
}

private func latestPointPerDate<T: DateIdentifiable>(_ points: [T]) -> [T] {
    latestPerDate(points) { $0.date }
}

// MARK: - Chart Data Point Structs

struct PLPoint: DateIdentifiable {
    let id: String
    let date: String
    let realized: Double
    let liquid: Double
}

struct APYPoint: DateIdentifiable {
    let id: String
    let date: String
    let realizedAPY: Double
    let liquidAPY: Double
}

struct ProfitPoint: DateIdentifiable {
    let id: String
    let date: String
    let cumDividend: Double
    let cumInterest: Double
    let cumExtracted: Double
    var total: Double { cumDividend + cumInterest + cumExtracted }
}

struct ValuePoint: DateIdentifiable {
    let id: String
    let date: String
    let value: Double
    let invested: Double
    let target: Double
}

struct DerivativesChartPoint: DateIdentifiable {
    let id: String
    let date: String
    // Value & Allocation
    let costBasis: Double
    let positionValue: Double
    // Price & Liquidation
    let avgEntry: Double
    let liqPrice: Double
    let position: Double
    // Capital & Leverage
    let marginBalance: Double
    let marginLocked: Double
    let leverage: Double
    // P&L
    let capturedProfit: Double
    let liquidPL: Double
    // APY
    let realizedAPY: Double
    let liquidAPY: Double
    // Captured Profit breakdown
    let sumRealized: Double
    let sumFunding: Double
    let sumInterest: Double
    let sumRebates: Double
    let sumFees: Double
}

// MARK: - Chart Computation Helpers

private func chartConfig(_ config: FundConfig) -> FundConfig {
    var c = config
    c.status = .active
    return c
}

func computePLPoints(entries: [FundEntry], config: FundConfig) -> [PLPoint] {
    let isCash = isCashFund(config.fund_type)

    let ordered = sortedByDateStable(entries)
    let allPoints: [PLPoint]

    if isCash {
        var realized = 0.0
        allPoints = ordered.map { entry in
            realized += entry.cash_interest ?? 0
            realized -= entry.expense ?? 0
            return PLPoint(id: entry.date, date: entry.date, realized: realized, liquid: realized)
        }
    } else {
        let rows = computeEntryRows(entries: ordered, config: chartConfig(config))
        allPoints = zip(ordered, rows).map { entry, row in
            PLPoint(id: entry.date, date: entry.date, realized: row.realized, liquid: row.liquidPnl)
        }
    }

    return sampleArray(latestPointPerDate(allPoints))
}

func computeAPYPoints(entries: [FundEntry], config: FundConfig) -> [APYPoint] {
    let isCash = isCashFund(config.fund_type)

    if isCash {
        return computeCashAPYPoints(entries: entries, config: chartConfig(config))
    }

    // Use the same per-entry computation as the entries table (matches web app),
    // then collapse to end-of-day and sample for chart display
    let ordered = sortedByDateStable(entries)
    let rows = computeEntryRows(entries: ordered, config: config)
    let allPoints = zip(ordered, rows).map { entry, row in
        APYPoint(id: entry.date, date: entry.date, realizedAPY: row.realizedApy, liquidAPY: row.liquidApy)
    }
    return sampleArray(latestPointPerDate(allPoints))
}

/// Cash fund APY uses TWAB (time-weighted average balance) as denominator — matches web app
private func computeCashAPYPoints(entries: [FundEntry], config: FundConfig) -> [APYPoint] {
    let startDate = getFundStartDate(entries)
    var twabNumerator = 0.0
    var lastBalance = 0.0
    var lastDate: String?
    var sumInterest = 0.0
    var sumExpenses = 0.0

    var all: [APYPoint] = []
    for entry in sortedByDateStable(entries) {
        if let ld = lastDate {
            let daysBtw = max(0, Double(daysBetween(ld, entry.date)))
            twabNumerator += lastBalance * daysBtw
        }
        if let ci = entry.cash_interest { sumInterest += ci }
        if let exp = entry.expense { sumExpenses += exp }

        lastBalance = entry.cash ?? entry.value
        lastDate = entry.date

        let days = max(1, daysBetween(startDate, entry.date))
        let twab = Double(days) > 0 ? twabNumerator / Double(days) : 0
        let basis = twab > 0 ? twab : lastBalance
        let realized = sumInterest - sumExpenses
        let apy = abs(realized) >= 0.01 && basis > 0
            ? computeCompoundAPY(realized / basis, days)
            : 0.0
        all.append(APYPoint(id: entry.date, date: entry.date, realizedAPY: apy, liquidAPY: apy))
    }
    return sampleArray(latestPointPerDate(all))
}

func computeProfitPoints(entries: [FundEntry], config: FundConfig) -> [ProfitPoint] {
    let isAccumulate = config.accumulate == true
    var cumD = 0.0
    var cumI = 0.0
    var cumE = 0.0
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0
    var costBasis = 0.0
    let all = sortedByDateStable(entries).map { entry -> ProfitPoint in
        cumD += entry.dividend ?? 0
        cumI += entry.cash_interest ?? 0
        if entry.action == .BUY, let amt = entry.amount {
            totalBuys += amt
            costBasis += amt
            sumShares += abs(entry.shares ?? 0)
        } else if entry.action == .SELL, let amt = entry.amount {
            totalSells += amt
            sumShares -= abs(entry.shares ?? 0)
            if isFullLiquidation(shares: entry.shares, value: entry.value, amount: amt, sumShares: sumShares, totalBuys: totalBuys, totalSells: totalSells) {
                cumE += max(0, totalSells - totalBuys)
                totalBuys = 0; totalSells = 0; sumShares = 0; costBasis = 0
            } else if isAccumulate {
                cumE += amt
                totalSells = 0
            } else {
                let hasShareTracking = entry.shares != nil && (entry.shares ?? 0) != 0
                if hasShareTracking && costBasis > 0 {
                    let sharesBeforeSell = sumShares + abs(entry.shares ?? 0)
                    let sellFraction = sharesBeforeSell > 0 ? abs(entry.shares ?? 0) / sharesBeforeSell : 1.0
                    let costBasisReturned = costBasis * sellFraction
                    cumE += max(0, amt - costBasisReturned)
                    costBasis -= costBasisReturned
                    totalBuys -= costBasisReturned
                    totalSells = 0
                }
            }
        }
        return ProfitPoint(id: entry.date, date: entry.date, cumDividend: cumD, cumInterest: cumI, cumExtracted: cumE)
    }
    return sampleArray(latestPointPerDate(all))
}

func computeValuePoints(entries: [FundEntry], config: FundConfig) -> [ValuePoint] {
    let isAccumulate = config.accumulate == true
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0

    // Single pass: compute net invested per entry
    let ordered = sortedByDateStable(entries)
    let allWithInvested: [(entry: FundEntry, invested: Double)] = ordered.map { entry in
        if entry.action == .BUY, let amt = entry.amount {
            totalBuys += amt
            sumShares += abs(entry.shares ?? 0)
        } else if entry.action == .SELL, let amt = entry.amount {
            totalSells += amt
            sumShares -= abs(entry.shares ?? 0)
            if isFullLiquidation(shares: entry.shares, value: entry.value, amount: amt, sumShares: sumShares, totalBuys: totalBuys, totalSells: totalSells) {
                totalBuys = 0; totalSells = 0; sumShares = 0
            } else if isAccumulate {
                totalSells = 0
            } else {
                let hasShareTracking = entry.shares != nil && (entry.shares ?? 0) != 0
                if hasShareTracking && totalBuys > 0 {
                    let sharesBeforeSell = sumShares + abs(entry.shares ?? 0)
                    let sellFraction = sharesBeforeSell > 0 ? abs(entry.shares ?? 0) / sharesBeforeSell : 1.0
                    totalBuys -= totalBuys * sellFraction
                    totalSells = 0
                }
            }
        }
        return (entry, max(0, totalBuys - totalSells))
    }

    // Collapse to end-of-day, sample, then compute target per sampled point
    let sampled = sampleArray(latestPerDate(allWithInvested) { $0.entry.date })

    let cc = chartConfig(config)

    // The original computed the prior set as `entries.filter { $0.date <= sampledDate }`
    // per sampled point — O(points × entries). `computeExpectedTarget` re-sorts its
    // trades internally, so only the *set* of prior entries matters, not their order.
    // Sort the dates once and binary-search the upper bound per sampled point, so the
    // prior prefix is recovered in O(log n).
    let dateSorted = ordered
    let sortedDates = dateSorted.map(\.date)
    return sampled.map { item in
        // Count of entries with date <= sampled date (upper-bound index).
        var lo = 0
        var hi = sortedDates.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedDates[mid] <= item.entry.date { lo = mid + 1 } else { hi = mid }
        }
        let prior = Array(dateSorted[0..<lo])
        let trades = entriesToTrades(prior)
        let target = computeExpectedTarget(config: cc, trades: trades, asOfDate: item.entry.date)
        return ValuePoint(id: item.entry.date, date: item.entry.date, value: item.entry.value, invested: item.invested, target: target)
    }
}

func computeDerivativesChartData(entries: [FundEntry], config: FundConfig) -> [DerivativesChartPoint] {
    let cm = config.contract_multiplier ?? 0.01
    let imr = config.initial_margin_rate ?? 0.25
    let mmr = config.maintenance_margin_rate ?? 0.20
    let ordered = sortedByDateStable(entries)
    let startDate = ordered.first?.date ?? ""
    var acc = DerivativesAccumulator()

    let all = ordered.map { entry -> DerivativesChartPoint in
        acc.apply(entry)

        // Use TSV values if available, otherwise compute from trade data
        let avgCostPerContract = acc.avgCostPerContract
        let position = acc.position
        let lastTradePrice = acc.lastTradePrice
        let avgEntry = entry.entry_price ?? (position > 0 ? avgCostPerContract / cm : 0)
        let costBasis = acc.totalBuyCost
        let marginLocked = entry.margin_locked ?? (position > 0 ? position * avgCostPerContract * imr : 0)

        // Dynamic leverage = Current Notional / Margin Locked (matches Coinbase's display)
        // Note: lastTradePrice and avgCostPerContract are already per-contract USD, no cm needed
        let currentNotional = position * (lastTradePrice > 0 ? lastTradePrice : avgCostPerContract)
        let leverage = marginLocked > 0 ? currentNotional / marginLocked : 0

        // Unrealized P&L: use TSV if available, else estimate from last trade price
        let unrealized = entry.unrealized_pnl ?? ((lastTradePrice - avgCostPerContract) * position)
        let positionValue = costBasis + unrealized

        // Liquidation price: use TSV if available, else compute
        // Negative = over-collateralized (safe), shown below zero on chart
        let liqPrice: Double = entry.liquidation_price ?? {
            guard position > 0 else { return 0 }
            let notionalSize = position * cm
            return (costBasis - acc.marginBalance) / (notionalSize * (1.0 - mmr))
        }()

        // Margin balance: prefer TSV cash if available
        let effectiveMarginBalance = entry.cash ?? acc.marginBalance

        let capturedProfit = acc.cumRealized + acc.cumFunding + acc.cumInterest + acc.cumRebates - acc.cumFees
        let liquidPL = capturedProfit + unrealized

        let days = Double(max(1, daysBetween(startDate, entry.date)))
        let capitalBase = max(1.0, effectiveMarginBalance - liquidPL)
        let realizedAPY = capturedProfit / capitalBase * (FundMath.daysPerYear / days)
        let liquidAPY = liquidPL / capitalBase * (FundMath.daysPerYear / days)

        return DerivativesChartPoint(
            id: entry.id,
            date: entry.date,
            costBasis: costBasis,
            positionValue: positionValue,
            avgEntry: avgEntry,
            liqPrice: liqPrice,
            position: position,
            marginBalance: effectiveMarginBalance,
            marginLocked: marginLocked,
            leverage: leverage,
            capturedProfit: capturedProfit,
            liquidPL: liquidPL,
            realizedAPY: realizedAPY,
            liquidAPY: liquidAPY,
            sumRealized: acc.cumRealized,
            sumFunding: acc.cumFunding,
            sumInterest: acc.cumInterest,
            sumRebates: acc.cumRebates,
            sumFees: acc.cumFees
        )
    }

    // Aggregate by date — keep only the last entry per date (end-of-day snapshot)
    return sampleArray(latestPointPerDate(all))
}
