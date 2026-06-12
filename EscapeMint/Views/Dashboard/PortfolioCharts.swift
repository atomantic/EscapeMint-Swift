import SwiftUI
import Charts

// Portfolio time-series computation (FundMetricsCursor, computePortfolioTimeSeries,
// PortfolioTimeSeriesPoint) lives in Engine/PortfolioTimeSeries.swift.

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

    private var slices: [(label: String, value: Double, color: Color)] {
        let palette = Color.platformPalette
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
                color: palette[i % palette.count]
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
                .frame(height: Layout.dashboardChartHeight)
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
                .frame(height: Layout.dashboardChartHeight)
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
                .frame(height: Layout.dashboardChartHeight)
            } else {
                emChartPlaceholder
            }
        }
    }
}

struct DashboardFundSizeChart: View {
    let points: [PortfolioTimeSeriesPoint]
    @State private var hoverIndex: Int?

    private let fundColors = Color.fundPalette

    var body: some View {
        let data = points
        // Collect unique fund tickers across all points (ordered by final value)
        let tickers: [String] = data.last?.sortedTickers ?? []

        EMChartCard(title: "Total Fund Size") {
            ForEach(tickers.prefix(5).indices, id: \.self) { i in
                LegendDot(color: fundColors[i % fundColors.count], label: tickers[i])
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
                    range: tickers.indices.map { fundColors[$0 % fundColors.count] }
                )
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: data, hoverIndex: $hoverIndex) { pt in
                        tickers.prefix(5).enumerated().map { i, ticker in
                            (label: ticker, value: formatCurrency(pt.perFundValues[ticker] ?? 0), color: fundColors[i % fundColors.count])
                        }
                    }
                }
                .frame(height: Layout.dashboardChartHeight)
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
                .frame(height: Layout.dashboardChartHeight)
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
                    .frame(height: Layout.dashboardChartHeight)
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
                .frame(height: Layout.dashboardChartHeight)
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
        .frame(height: Layout.dashboardChartHeight)
}
