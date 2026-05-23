import SwiftUI
import Charts

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
            let totalReturn = max(-0.99, totalRealizedGains / avgCapital)
            realizedAPY = pow(1.0 + totalReturn, 365.0 / Double(effectivePortfolioDays)) - 1.0
        }
        let totalGainUsd = totalRealizedGains + totalUnrealizedGains
        var liquidAPY = 0.0
        if avgCapital > 0 && effectivePortfolioDays > 0 {
            let liquidReturn = max(-0.99, totalGainUsd / avgCapital)
            liquidAPY = pow(1.0 + liquidReturn, 365.0 / Double(effectivePortfolioDays)) - 1.0
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

// MARK: - Allocation Pie Charts

struct FundAllocationChart: View {
    let summaries: [FundSummary]

    private var slices: [(label: String, value: Double, color: Color)] {
        summaries
            .filter { $0.currentValue > 0 }
            .sorted { $0.currentValue > $1.currentValue }
            .prefix(10)
            .map { s in
                (
                    label: s.fund.ticker.uppercased(),
                    value: s.currentValue,
                    color: Color.forCategory(s.fund.config.category)
                )
            }
    }

    var body: some View {
        AllocationPieChart(title: "Fund Allocation", slices: slices)
    }
}

struct PlatformAllocationChart: View {
    let summaries: [FundSummary]

    private static let platformColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .brown, .indigo
    ]

    private var slices: [(label: String, value: Double, color: Color)] {
        let grouped = Dictionary(grouping: summaries, by: { $0.fund.platform })
        return grouped.map { platform, sums in
            (platform.capitalized, sums.reduce(0.0) { $0 + $1.currentValue })
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .enumerated()
        .map { i, item in
            (
                label: item.0,
                value: item.1,
                color: Self.platformColors[i % Self.platformColors.count]
            )
        }
    }

    var body: some View {
        AllocationPieChart(title: "Platform Allocation", slices: slices)
    }
}

struct PortfolioAllocationChart: View {
    let summaries: [FundSummary]

    private static let categoryOrder: [FundCategory] = [.liquidity, .yield, .sov, .volatility]

    private var categories: [(label: String, value: Double, color: Color)] {
        let grouped = Dictionary(grouping: summaries, by: { s -> FundCategory in
            if s.isCash { return .liquidity }
            return s.fund.config.category ?? .volatility
        })
        return Self.categoryOrder.compactMap { cat in
            guard let sums = grouped[cat] else { return nil }
            let info = categoryConfig[cat]
            let value = sums.reduce(0.0) { $0 + $1.currentValue }
            guard value > 0 else { return nil }
            return (
                label: info?.label ?? cat.rawValue,
                value: value,
                color: info?.color ?? .gray
            )
        }
    }

    private var total: Double { categories.reduce(0) { $0 + $1.value } }

    private var marginStats: (available: Double, borrowed: Double) {
        summaries.reduce((0.0, 0.0)) { acc, s in
            let entry = s.fund.entries.last
            return (acc.0 + (entry?.margin_available ?? 0), acc.1 + (entry?.margin_borrowed ?? 0))
        }
    }

    var body: some View {
        let margin = marginStats
        VStack(alignment: .leading, spacing: 8) {
            Text("Portfolio Allocation")
                .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)

            ForEach(categories.indices, id: \.self) { i in
                let cat = categories[i]
                let pct = total > 0 ? cat.value / total : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(cat.label)
                            .font(.caption).foregroundColor(.textSecondary)
                        Spacer()
                        Text(formatCurrency(cat.value))
                            .font(.caption).fontWeight(.medium).foregroundColor(.textPrimary)
                        Text(formatPercent(pct))
                            .font(.caption2).foregroundColor(.textMuted)
                            .frame(width: 44, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cat.color)
                            .frame(width: geo.size.width * pct, height: 6)
                    }
                    .frame(height: 6)
                }
            }

            if margin.available > 0 || margin.borrowed > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Margin Capacity")
                            .font(.caption).foregroundColor(.textSecondary)
                        Spacer()
                        Text(formatCurrency(margin.available))
                            .font(.caption).fontWeight(.medium).foregroundColor(.textPrimary)
                        if margin.borrowed > 0 {
                            Text("(\(formatCurrency(margin.borrowed)) used)")
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                    GeometryReader { geo in
                        let totalMargin = margin.available + margin.borrowed
                        let borrowedPct = totalMargin > 0 ? margin.borrowed / totalMargin : 0
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.purple, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .frame(height: 6)
                            if borrowedPct > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.purple)
                                    .frame(width: geo.size.width * borrowedPct, height: 6)
                            }
                        }
                    }
                    .frame(height: 6)
                    Text("Borrowing capacity from holdings (not an allocation)")
                        .font(.caption2).foregroundColor(.textMuted)
                }
            }
        }
        .padding(8)
        .cardStyle()
    }
}

private struct AllocationPieChart: View {
    let title: String
    let slices: [(label: String, value: Double, color: Color)]

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)

            HStack(spacing: 12) {
                Chart(slices.indices, id: \.self) { i in
                    let slice = slices[i]
                    SectorMark(
                        angle: .value(slice.label, slice.value),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(slice.color)
                }
                .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slices.prefix(6).indices, id: \.self) { i in
                        let slice = slices[i]
                        let pct = total > 0 ? slice.value / total : 0
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(slice.label)
                                    .font(.caption).foregroundColor(.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatCurrency(slice.value))
                                    .font(.caption).fontWeight(.medium).foregroundColor(.textPrimary)
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(slice.color)
                                    .frame(width: geo.size.width * pct, height: 4)
                            }
                            .frame(height: 4)
                        }
                    }
                    if slices.count > 6 {
                        Text("+ \(slices.count - 6) more")
                            .font(.caption2).foregroundColor(.textMuted)
                    }
                }
            }
        }
        .padding(8)
        .cardStyle()
    }
}

// MARK: - Dashboard Time Series Charts

struct DashboardAPYChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        let data = points
        let hasNegative = data.contains { $0.realizedAPY < 0 || $0.liquidAPY < 0 }

        EMChartCard(title: "APY") {
            if let last = data.last {
                LegendDot(color: .mint, label: "R: \(formatPercent(last.realizedAPY))")
                LegendDot(color: .blue, label: "L: \(formatPercent(last.liquidAPY))")
            }
        } chart: {
            if data.count >= 2 {
                Chart {
                    ForEach(data) { pt in
                        let d = pt.parsedDate
                        AreaMark(x: .value("Date", d), y: .value("L.APY", pt.liquidAPY))
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("R.APY", pt.realizedAPY))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("L.APY", pt.liquidAPY))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emPercentAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Realized", value: formatPercent(pt.realizedAPY), color: .mint),
                            (label: "Liquid", value: formatPercent(pt.liquidAPY), color: .blue),
                        ]
                    }
                }
                .frame(height: 150)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardGainChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        let data = points
        let hasNegative = data.contains { $0.realized < 0 || $0.liquid < 0 }

        EMChartCard(title: "Gain ($)") {
            if let last = data.last {
                LegendDot(color: .mint, label: "R: \(formatCurrency(last.realized))")
                LegendDot(color: .orange, label: "U: \(formatCurrency(last.unrealized))")
                LegendDot(color: .blue, label: "L: \(formatCurrency(last.liquid))")
            }
        } chart: {
            if data.count >= 2 {
                Chart {
                    ForEach(data) { pt in
                        let d = pt.parsedDate
                        AreaMark(x: .value("Date", d), y: .value("Liquid", pt.liquid))
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Realized", pt.realized))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Unrealized", pt.unrealized))
                            .foregroundStyle(by: .value("Type", "Unrealized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Liquid", pt.liquid))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Unrealized": Color.orange, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Realized", value: formatCurrency(pt.realized), color: .mint),
                            (label: "Unrealized", value: formatCurrency(pt.unrealized), color: .orange),
                            (label: "Liquid", value: formatCurrency(pt.liquid), color: .blue),
                        ]
                    }
                }
                .frame(height: 150)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardValueChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        let data = points

        EMChartCard(title: "Value & Allocation") {
            if let last = data.last {
                LegendDot(color: .orange, label: "V: \(formatCurrency(last.totalValue))")
                LegendDot(color: .purple, label: "I: \(formatCurrency(last.totalInvested))")
            }
        } chart: {
            if data.count >= 2 {
                Chart(data) { pt in
                    let d = pt.parsedDate
                    AreaMark(x: .value("Date", d), y: .value("Invested", pt.totalInvested))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [Color.purple.opacity(0.2), Color.purple.opacity(0.0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", d), y: .value("Value", pt.totalValue))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Value", value: formatCurrency(pt.totalValue), color: .orange),
                            (label: "Invested", value: formatCurrency(pt.totalInvested), color: .purple),
                        ]
                    }
                }
                .frame(height: 150)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardFundSizeChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    private static let fundColors: [Color] = [
        .blue, .mint, .orange, .purple, .pink, .cyan, .yellow, .green, .red, .indigo
    ]

    var body: some View {
        let data = points
        // Collect unique fund tickers across all points (ordered by final value)
        let tickers: [String] = data.last?.sortedTickers ?? []

        EMChartCard(title: "Total Fund Size") {
            ForEach(tickers.prefix(5).indices, id: \.self) { i in
                LegendDot(color: Self.fundColors[i % Self.fundColors.count], label: tickers[i])
            }
        } chart: {
            if data.count >= 2 && !tickers.isEmpty {
                Chart {
                    ForEach(data) { pt in
                        ForEach(tickers.indices, id: \.self) { i in
                            let ticker = tickers[i]
                            AreaMark(
                                x: .value("Date", pt.parsedDate),
                                y: .value("Value", pt.perFundValues[ticker] ?? 0),
                                stacking: .standard
                            )
                            .foregroundStyle(by: .value("Fund", ticker))
                            .interpolationMethod(.linear)
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: tickers,
                    range: tickers.indices.map { Self.fundColors[$0 % Self.fundColors.count] }
                )
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        tickers.prefix(5).enumerated().map { i, ticker in
                            (label: ticker, value: formatCurrency(pt.perFundValues[ticker] ?? 0), color: Self.fundColors[i % Self.fundColors.count])
                        }
                    }
                }
                .frame(height: 150)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardLiquidValueChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        let data = points

        EMChartCard(title: "Liquid Value") {
            LegendDot(color: .mint, label: "Cash")
            LegendDot(color: .purple, label: "Assets")
        } chart: {
            if data.count >= 2 {
                Chart(data) { pt in
                    let d = pt.parsedDate
                    AreaMark(
                        x: .value("Date", d),
                        y: .value("Value", pt.cashBalance),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Type", "Cash"))
                    .interpolationMethod(.linear)
                    AreaMark(
                        x: .value("Date", d),
                        y: .value("Value", pt.assetValue),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Type", "Assets"))
                    .interpolationMethod(.linear)
                }
                .chartForegroundStyleScale(["Cash": Color.mint.opacity(0.6), "Assets": Color.purple.opacity(0.6)])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Cash", value: formatCurrency(pt.cashBalance), color: .mint),
                            (label: "Assets", value: formatCurrency(pt.assetValue), color: .purple),
                        ]
                    }
                }
                .frame(height: 150)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardMarginChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    private var hasMarginData: Bool {
        points.contains { $0.marginAccess > 0 || $0.marginBorrowed > 0 }
    }

    @ViewBuilder
    var body: some View {
        if hasMarginData {
            let firstMarginIdx = points.firstIndex { $0.marginAccess > 0 || $0.marginBorrowed > 0 } ?? 0
            let data = Array(points[firstMarginIdx...])
            EMChartCard(title: "Margin") {
                if let last = data.last {
                    LegendDot(color: .green, label: "Avail: \(formatCurrency(last.marginAccess))")
                    LegendDot(color: .red, label: "Borrow: \(formatCurrency(last.marginBorrowed))")
                }
            } chart: {
                if data.count >= 2 {
                    Chart(data) { pt in
                        let d = pt.parsedDate
                        AreaMark(x: .value("Date", d), y: .value("Amount", pt.marginAccess), stacking: .unstacked)
                            .foregroundStyle(by: .value("Series", "Avail"))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Date", d), y: .value("Amount", pt.marginBorrowed), stacking: .unstacked)
                            .foregroundStyle(by: .value("Series", "Borrow"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Amount", pt.marginAccess))
                            .foregroundStyle(by: .value("Series", "Avail"))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Amount", pt.marginBorrowed))
                            .foregroundStyle(by: .value("Series", "Borrow"))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale(["Avail": Color.green.opacity(0.6), "Borrow": Color.red.opacity(0.6)])
                    .chartXAxis { emDateAxisTemporal() }
                    .chartYAxis { emCurrencyAxis() }
                    .chartLegend(.hidden)
                    .chartOverlay { proxy in
                        chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                            [
                                (label: "Available", value: formatCurrency(pt.marginAccess), color: .green),
                                (label: "Borrowed", value: formatCurrency(pt.marginBorrowed), color: .red),
                            ]
                        }
                    }
                    .frame(height: 150)
                } else {
                    emChartPlaceholder
                }
            }
        }
    }
}

struct DashboardCashVsAssetChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        let data = points

        EMChartCard(title: "Cash vs Asset") {
            if let last = data.last {
                let total = last.cashBalance + last.assetValue
                let cashPct = total > 0 ? last.cashBalance / total : 0
                let assetPct = total > 0 ? last.assetValue / total : 0
                LegendDot(color: .mint, label: "Cash \(formatPercent(cashPct))")
                LegendDot(color: .purple, label: "Asset \(formatPercent(assetPct))")
            }
        } chart: {
            if data.count >= 2 {
                Chart(data) { pt in
                    let d = pt.parsedDate
                    let total = pt.cashBalance + pt.assetValue
                    let cashPct = total > 0 ? pt.cashBalance / total : 0
                    let assetPct = total > 0 ? pt.assetValue / total : 0
                    AreaMark(
                        x: .value("Date", d),
                        y: .value("Pct", cashPct),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Type", "Cash"))
                    .interpolationMethod(.monotone)
                    AreaMark(
                        x: .value("Date", d),
                        y: .value("Pct", assetPct),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Type", "Asset"))
                    .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(["Cash": Color.mint.opacity(0.6), "Asset": Color.purple.opacity(0.6)])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emPercentAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        let total = pt.cashBalance + pt.assetValue
                        let cashPct = total > 0 ? pt.cashBalance / total : 0
                        let assetPct = total > 0 ? pt.assetValue / total : 0
                        return [
                            (label: "Cash", value: formatPercent(cashPct), color: .mint),
                            (label: "Asset", value: formatPercent(assetPct), color: .purple),
                        ]
                    }
                }
                .frame(height: 150)
            } else {
                emChartPlaceholder
            }
        }
    }
}

// MARK: - Shared Chart Components

struct EMChartCard<Legend: View, ChartContent: View>: View {
    let title: String
    @ViewBuilder let legend: () -> Legend
    @ViewBuilder let chart: () -> ChartContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)
                Spacer()
                HStack(spacing: 6) { legend() }
            }
            chart()
        }
        .padding(8)
        .cardStyle()
    }
}

struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundColor(.textSecondary)
        }
    }
}

private var emChartPlaceholder: some View {
    Text("Not enough data for chart")
        .font(.caption).foregroundColor(.textMuted)
        .frame(maxWidth: .infinity)
        .frame(height: 150)
}
