import SwiftUI
import Charts

// MARK: - Portfolio Time Series Data

struct PortfolioTimeSeriesPoint: Identifiable {
    let id: String
    let date: String
    let parsedDate: Date
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

func computePortfolioTimeSeries(_ funds: [FundData]) -> [PortfolioTimeSeriesPoint] {
    let activeFunds = funds.filter { $0.config.status != .closed }
    guard !activeFunds.isEmpty else { return [] }

    var allDates = Set<String>()
    for fund in activeFunds {
        for entry in fund.entries { allDates.insert(entry.date) }
    }
    let sortedDates = allDates.sorted()
    let sampled = sampleArray(sortedDates)

    return sampled.map { date in
        // Reuse computePortfolioMetrics for APY/gains (consistent calculation)
        let pm = computePortfolioMetrics(funds, asOfDate: date)

        // Collect per-fund values and margin data (not in PortfolioMetrics)
        var marginAccess = 0.0
        var marginBorrowed = 0.0
        var perFund: [String: Double] = [:]

        for fund in activeFunds {
            guard let lastEntry = fund.entries.last(where: { $0.date <= date }) else { continue }
            perFund[fund.ticker.uppercased()] = lastEntry.value
            marginAccess += lastEntry.margin_available ?? 0
            marginBorrowed += lastEntry.margin_borrowed ?? 0
        }

        let tickers = perFund.sorted { $0.value > $1.value }.map(\.key)

        return PortfolioTimeSeriesPoint(
            id: date, date: date,
            parsedDate: isoDateFormatter.date(from: date) ?? Date(),
            realizedAPY: pm.realizedAPY, liquidAPY: pm.liquidAPY,
            realized: pm.totalRealizedGains, unrealized: pm.totalUnrealizedGains,
            liquid: pm.totalGainUsd,
            totalValue: pm.totalValue, totalInvested: pm.totalStartInput,
            totalFundSize: pm.totalFundSize,
            cashBalance: pm.cashBalance, assetValue: pm.totalValue - pm.cashBalance,
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

    private var slices: [(label: String, value: Double, color: Color)] {
        let grouped = Dictionary(grouping: summaries.filter { !$0.isCash }, by: { $0.fund.config.category ?? .volatility })
        return grouped.map { cat, sums in
            let info = categoryConfig[cat]
            return (
                label: info?.label ?? cat.rawValue,
                value: sums.reduce(0.0) { $0 + $1.currentValue },
                color: info?.color ?? .gray
            )
        }
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
    }

    var body: some View {
        AllocationPieChart(title: "Portfolio Allocation", slices: slices)
    }
}

private struct AllocationPieChart: View {
    let title: String
    let slices: [(label: String, value: Double, color: Color)]

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline).foregroundColor(.textPrimary)

            HStack(spacing: 16) {
                Chart(slices.indices, id: \.self) { i in
                    let slice = slices[i]
                    SectorMark(
                        angle: .value(slice.label, slice.value),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(slice.color)
                }
                .frame(width: 100, height: 100)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slices.prefix(6).indices, id: \.self) { i in
                        let slice = slices[i]
                        let pct = total > 0 ? slice.value / total : 0
                        HStack(spacing: 6) {
                            Circle().fill(slice.color).frame(width: 6, height: 6)
                            Text(slice.label)
                                .font(.caption).foregroundColor(.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            Text(formatCurrency(slice.value))
                                .font(.caption).foregroundColor(.textPrimary)
                            Text(formatPercent(pct))
                                .font(.caption2).foregroundColor(.textMuted)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    if slices.count > 6 {
                        Text("+ \(slices.count - 6) more")
                            .font(.caption2).foregroundColor(.textMuted)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

// MARK: - Dashboard Time Series Charts

struct DashboardAPYChart: View {
    let points: [PortfolioTimeSeriesPoint]

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
                .frame(height: 180)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardGainChart: View {
    let points: [PortfolioTimeSeriesPoint]

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
                .frame(height: 180)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardValueChart: View {
    let points: [PortfolioTimeSeriesPoint]

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
                        .foregroundStyle(Color.purple.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", d), y: .value("Value", pt.totalValue))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .frame(height: 180)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardFundSizeChart: View {
    let points: [PortfolioTimeSeriesPoint]

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
                            .interpolationMethod(.monotone)
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
                .frame(height: 180)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardLiquidValueChart: View {
    let points: [PortfolioTimeSeriesPoint]

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
                    .interpolationMethod(.monotone)
                    AreaMark(
                        x: .value("Date", d),
                        y: .value("Value", pt.assetValue),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Type", "Assets"))
                    .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(["Cash": Color.mint.opacity(0.6), "Assets": Color.purple.opacity(0.6)])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .frame(height: 180)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardMarginChart: View {
    let points: [PortfolioTimeSeriesPoint]

    private var hasMarginData: Bool {
        points.contains { $0.marginAccess > 0 || $0.marginBorrowed > 0 }
    }

    @ViewBuilder
    var body: some View {
        if hasMarginData {
            let data = points.filter { $0.marginAccess > 0 || $0.marginBorrowed > 0 }
            EMChartCard(title: "Margin") {
                if let last = data.last {
                    LegendDot(color: .green, label: "Avail: \(formatCurrency(last.marginAccess))")
                    LegendDot(color: .red, label: "Borrow: \(formatCurrency(last.marginBorrowed))")
                }
            } chart: {
                if data.count >= 2 {
                    Chart(data) { pt in
                        let d = pt.parsedDate
                        AreaMark(x: .value("Date", d), y: .value("Access", pt.marginAccess))
                            .foregroundStyle(Color.green.opacity(0.1))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Date", d), y: .value("Borrowed", pt.marginBorrowed))
                            .foregroundStyle(Color.red.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Access", pt.marginAccess))
                            .foregroundStyle(Color.green)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Borrowed", pt.marginBorrowed))
                            .foregroundStyle(Color.red)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis { emDateAxisTemporal() }
                    .chartYAxis { emCurrencyAxis() }
                    .frame(height: 180)
                } else {
                    emChartPlaceholder
                }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline).foregroundColor(.textPrimary)
                Spacer()
                HStack(spacing: 8) { legend() }
            }
            chart()
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
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
        .frame(height: 180)
}

