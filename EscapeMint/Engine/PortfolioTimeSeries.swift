import Foundation

// MARK: - Portfolio Time Series Data

struct PortfolioTimeSeriesPoint: DateIdentifiable {
    let id: String
    let date: String
    let parsedDate: Date
    var dateValue: Date { parsedDate }
    let realizedAPY: Double
    let liquidAPY: Double
    let realized: Double
    let unrealized: Double
    let liquid: Double
    let totalValue: Double
    let totalInvested: Double
    let totalFundSize: Double
    let cashBalance: Double
    let assetValue: Double
    let marginAccess: Double
    let marginBorrowed: Double
    let perFundValues: [String: Double]
    let sortedTickers: [String]
}

// MARK: - Incremental Fund Metrics Cursor

/// Lightweight per-fund metrics snapshot for time series aggregation
private struct FundSnapshotMetrics {
    let fundSize: Double
    let currentValue: Double
    let startInput: Double
    let realizedGains: Double
    let unrealizedGains: Double
    let twNumerator: Double // raw TWAP or TWAB numerator (includes final period)
    let daysActive: Int
    let isCash: Bool
    let isClosed: Bool
    let cashInterest: Double
}

/// Tracks running state for a single fund's entries, enabling O(total_entries)
/// computation across all sampled dates instead of O(dates × entries) per fund.
private struct FundMetricsCursor {
    let fund: FundData
    let sortedEntries: [FundEntry]
    let isCash: Bool
    let isAccumulate: Bool
    let manageCash: Bool
    let isDerivatives: Bool

    var index: Int = 0

    // Running state matching computeFundMetricsForFund single-pass walk
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0
    var costBasis = 0.0
    var sumDividends = 0.0
    var sumExpenses = 0.0
    var sumCashInterest = 0.0
    var sumExtracted = 0.0
    var twapNumerator = 0.0
    var twapLastDate: String?
    var twabNumerator = 0.0
    var lastCashBalance = 0.0
    var lastDate: String?
    var cycleStartDate: String?
    var cumulativeActiveDays = 0.0
    var hadFirstBuy = false

    init(fund: FundData) {
        self.fund = fund
        self.sortedEntries = fund.entries.sorted { $0.date < $1.date }
        let config = fund.config
        self.isCash = isCashFund(config.fund_type)
        self.isAccumulate = config.accumulate == true
        self.manageCash = config.manage_cash != false
        self.isDerivatives = config.fund_type == .derivatives
    }

    /// Advance cursor to include all entries with date <= target date
    mutating func advance(to date: String) {
        if isDerivatives {
            // Derivatives: just track index (finalize delegates to engine function)
            while index < sortedEntries.count && sortedEntries[index].date <= date {
                index += 1
            }
            return
        }
        while index < sortedEntries.count && sortedEntries[index].date <= date {
            processEntry(sortedEntries[index])
            index += 1
        }
    }

    private mutating func processEntry(_ entry: FundEntry) {
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
            let sharesLiquidated = hasShareTracking && abs(sumShares) < FundMath.shareDustThreshold
            let valueLiquidated = entry.value > 0 && entry.value <= amt + FundMath.currencyTolerance
            let isFullLiq = sharesLiquidated || valueLiquidated

            var extracted = 0.0
            if isFullLiq {
                extracted = amt - costBasis
                costBasis = 0
                totalBuys = 0
                totalSells = 0
                sumShares = 0
                if let csd = cycleStartDate {
                    cumulativeActiveDays += max(0, Double(daysBetween(csd, entry.date)))
                    cycleStartDate = nil
                }
            } else if isAccumulate {
                extracted = amt
            } else {
                let sellProportion = (entry.value + amt) > 0 ? amt / (entry.value + amt) : 1.0
                let costBasisReturned = costBasis * sellProportion
                extracted = amt - costBasisReturned
                costBasis -= costBasisReturned
                totalSells += amt
            }
            sumExtracted += extracted
        }

        if isCash { lastCashBalance = entry.cash ?? entry.value }
        lastDate = entry.date
    }

    /// Compute metrics snapshot at current cursor position (read-only, doesn't mutate state)
    func snapshot(asOfDate: String) -> FundSnapshotMetrics {
        // Derivatives: delegate to existing engine function for correctness
        if isDerivatives {
            var fundCopy = fund
            fundCopy.entries = index > 0 ? Array(sortedEntries[0..<index]) : []
            let (metrics, state) = computeFundMetricsForFund(fundCopy, asOfDate: asOfDate)
            return FundSnapshotMetrics(
                fundSize: metrics.fundSize, currentValue: metrics.currentValue,
                startInput: metrics.startInput, realizedGains: metrics.realizedGains,
                unrealizedGains: metrics.unrealizedGains,
                twNumerator: metrics.timeWeightedFundSize * Double(metrics.daysActive),
                daysActive: metrics.daysActive, isCash: false,
                isClosed: metrics.status == .closed, cashInterest: state.cashInterestUsd
            )
        }

        let config = fund.config
        let latestEntry = index > 0 ? sortedEntries[index - 1] : nil
        let endDate = config.status == .closed ? (latestEntry?.date ?? asOfDate) : asOfDate

        // Final TWAP period (from last processed entry to endDate)
        var finalTwapNum = twapNumerator
        if !isCash, let tld = twapLastDate, cycleStartDate != nil {
            let finalDays = max(0, Double(daysBetween(tld, endDate)))
            finalTwapNum += costBasis * finalDays
        }

        // Active days
        let daysActive: Int
        if hadFirstBuy {
            let currentCycleDays = cycleStartDate.map { max(0, Double(daysBetween($0, endDate))) } ?? 0
            daysActive = max(1, Int(cumulativeActiveDays + currentCycleDays))
        } else {
            let sd = sortedEntries.first?.date ?? asOfDate
            daysActive = max(1, daysBetween(sd, endDate))
        }

        // Current values
        let netInvested = max(0, totalBuys - totalSells)
        let computedFundSize: Double
        let currentValue: Double

        if config.status == .closed {
            computedFundSize = 0; currentValue = 0
        } else if isCash {
            let cashVal = latestEntry?.cash ?? latestEntry?.fund_size ?? latestEntry?.value ?? 0
            computedFundSize = latestEntry?.fund_size ?? cashVal
            currentValue = cashVal
        } else {
            var postActionValue = latestEntry?.value ?? 0
            if latestEntry?.action == .BUY, let amt = latestEntry?.amount {
                postActionValue += amt
            } else if latestEntry?.action == .SELL, let amt = latestEntry?.amount {
                postActionValue = max(0, postActionValue - amt)
            }
            currentValue = postActionValue
            computedFundSize = manageCash ? (latestEntry?.fund_size ?? 0) : (latestEntry?.fund_size ?? netInvested)
        }

        // Gains
        let unrealized = isCash ? 0 : (currentValue - costBasis)
        let realized = isCash
            ? sumCashInterest - sumExpenses
            : sumCashInterest + sumDividends + sumExtracted - sumExpenses

        let twNumerator = isCash ? twabNumerator : finalTwapNum
        let startInput = isCash ? (latestEntry?.cash ?? latestEntry?.fund_size ?? latestEntry?.value ?? 0) : costBasis

        return FundSnapshotMetrics(
            fundSize: computedFundSize, currentValue: currentValue,
            startInput: startInput, realizedGains: realized,
            unrealizedGains: unrealized, twNumerator: twNumerator,
            daysActive: daysActive, isCash: isCash,
            isClosed: config.status == .closed, cashInterest: sumCashInterest
        )
    }
}

// MARK: - Optimized Portfolio Time Series

func computePortfolioTimeSeries(_ funds: [FundData]) -> [PortfolioTimeSeriesPoint] {
    let activeFunds = funds.filter { $0.config.status != .closed }
    guard !activeFunds.isEmpty else { return [] }

    // Collect all unique dates from active funds and sample
    var allDates = Set<String>()
    for fund in activeFunds {
        for entry in fund.entries { allDates.insert(entry.date) }
    }
    let sortedDates = allDates.sorted()
    let sampled = sampleArray(sortedDates)
    guard !sampled.isEmpty else { return [] }

    // Initialize cursors — entries are sorted once per fund (not per date)
    var cursors = funds.map { FundMetricsCursor(fund: $0) }

    return sampled.map { date in
        // Advance all cursors — each entry is visited at most once across all dates
        for i in cursors.indices { cursors[i].advance(to: date) }

        // Aggregate per-fund snapshots directly. Avoiding a separate snapshot
        // array keeps the chart rebuild path allocation-light on every sampled date.
        var totalFundSize = 0.0, totalValue = 0.0, totalStartInput = 0.0
        var totalRealizedGains = 0.0, totalUnrealizedGains = 0.0
        var cashBalance = 0.0
        var totalDollarDays = 0.0
        var maxDaysActive = 0

        for cursor in cursors {
            let snap = cursor.snapshot(asOfDate: date)
            totalFundSize += snap.fundSize
            totalValue += snap.currentValue
            totalStartInput += snap.startInput
            totalRealizedGains += snap.realizedGains
            totalUnrealizedGains += snap.unrealizedGains
            totalDollarDays += snap.twNumerator
            maxDaysActive = max(maxDaysActive, snap.daysActive)
            if snap.isCash && !snap.isClosed { cashBalance += snap.currentValue }
        }

        // Portfolio days: calendar span from earliest to latest entry across all funds
        var earliestDate: String?
        var latestDate: String?
        for cursor in cursors {
            guard cursor.index > 0 else { continue }
            let first = cursor.sortedEntries[0].date
            let last = cursor.sortedEntries[cursor.index - 1].date
            if earliestDate == nil || first < earliestDate! { earliestDate = first }
            if latestDate == nil || last > latestDate! { latestDate = last }
        }
        let portfolioDays: Int
        if let e = earliestDate, let l = latestDate {
            portfolioDays = max(1, daysBetween(e, l))
        } else {
            portfolioDays = maxDaysActive
        }
        let effectivePortfolioDays = portfolioDays > 0 ? portfolioDays : maxDaysActive

        // Dollar-weighted compound APY (mirrors computePortfolioMetrics)
        let avgCapital = effectivePortfolioDays > 0 ? totalDollarDays / Double(effectivePortfolioDays) : 0
        var realizedAPY = 0.0
        if avgCapital > 0 && effectivePortfolioDays > 0 {
            let totalReturn = max(FundMath.minReturnRate, totalRealizedGains / avgCapital)
            realizedAPY = pow(1.0 + totalReturn, FundMath.daysPerYear / Double(effectivePortfolioDays)) - 1.0
        }
        let totalGainUsd = totalRealizedGains + totalUnrealizedGains
        var liquidAPY = 0.0
        if avgCapital > 0 && effectivePortfolioDays > 0 {
            let liquidReturn = max(FundMath.minReturnRate, totalGainUsd / avgCapital)
            liquidAPY = pow(1.0 + liquidReturn, FundMath.daysPerYear / Double(effectivePortfolioDays)) - 1.0
        }

        // Per-fund values and margin (active funds only)
        var perFund: [String: Double] = [:]
        var marginAccess = 0.0
        var marginBorrowed = 0.0
        for c in cursors where c.fund.config.status != .closed {
            guard c.index > 0 else { continue }
            let lastEntry = c.sortedEntries[c.index - 1]
            perFund[c.fund.ticker.uppercased()] = lastEntry.value
            marginAccess += lastEntry.margin_available ?? 0
            marginBorrowed += lastEntry.margin_borrowed ?? 0
        }
        let tickers = perFund.sorted { $0.value > $1.value }.map(\.key)

        return PortfolioTimeSeriesPoint(
            id: date, date: date,
            parsedDate: isoDateFormatter.date(from: date) ?? Date(),
            realizedAPY: realizedAPY, liquidAPY: liquidAPY,
            realized: totalRealizedGains, unrealized: totalUnrealizedGains,
            liquid: totalGainUsd,
            totalValue: totalValue, totalInvested: totalStartInput,
            totalFundSize: totalFundSize,
            cashBalance: cashBalance, assetValue: totalValue - cashBalance,
            marginAccess: marginAccess, marginBorrowed: marginBorrowed,
            perFundValues: perFund, sortedTickers: tickers
        )
    }
}
