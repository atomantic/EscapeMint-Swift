import SwiftUI
import Charts

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
                // Pie chart
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

                // Legend
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
    let funds: [FundData]

    private struct APYDataPoint: Identifiable {
        let id: String
        let date: String
        let realizedAPY: Double
        let liquidAPY: Double
    }

    private var points: [APYDataPoint] {
        // Collect all unique dates across all funds
        var allDates = Set<String>()
        for fund in funds where fund.config.status != .closed {
            for entry in fund.entries {
                allDates.insert(entry.date)
            }
        }
        let sortedDates = allDates.sorted()
        // Sample to max 60 points
        let step = max(1, sortedDates.count / 60)
        let sampled = sortedDates.enumerated()
            .filter { $0.offset % step == 0 || $0.offset == sortedDates.count - 1 }
            .map(\.element)

        return sampled.map { date in
            let pm = computePortfolioMetrics(funds, asOfDate: date)
            return APYDataPoint(id: date, date: date, realizedAPY: pm.realizedAPY, liquidAPY: pm.liquidAPY)
        }
    }

    var body: some View {
        let data = points
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("APY")
                    .font(.headline).foregroundColor(.textPrimary)
                Spacer()
                if let last = data.last {
                    HStack(spacing: 8) {
                        LegendDot(color: .mint, label: formatPercent(last.realizedAPY))
                        LegendDot(color: .red, label: formatPercent(-abs(last.liquidAPY > 0 ? 0 : last.liquidAPY)))
                        LegendDot(color: .blue, label: formatPercent(last.liquidAPY))
                    }
                }
            }

            if data.count >= 2 {
                Chart(data) { pt in
                    LineMark(x: .value("Date", pt.date), y: .value("R.APY", pt.realizedAPY))
                        .foregroundStyle(by: .value("Type", "Realized"))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", pt.date), y: .value("L.APY", pt.liquidAPY))
                        .foregroundStyle(by: .value("Type", "Liquid"))
                        .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let str = value.as(String.self) {
                                Text(String(str.suffix(5)))
                                    .font(.caption2).foregroundColor(.textMuted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatPercent(v))
                                    .font(.caption2).foregroundColor(.textMuted)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 180)
            } else {
                Text("Not enough data for chart")
                    .font(.caption).foregroundColor(.textMuted)
                    .frame(height: 180)
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

struct DashboardGainChart: View {
    let funds: [FundData]

    private struct GainDataPoint: Identifiable {
        let id: String
        let date: String
        let realized: Double
        let unrealized: Double
        let liquid: Double
    }

    private var points: [GainDataPoint] {
        var allDates = Set<String>()
        for fund in funds where fund.config.status != .closed {
            for entry in fund.entries {
                allDates.insert(entry.date)
            }
        }
        let sortedDates = allDates.sorted()
        let step = max(1, sortedDates.count / 60)
        let sampled = sortedDates.enumerated()
            .filter { $0.offset % step == 0 || $0.offset == sortedDates.count - 1 }
            .map(\.element)

        return sampled.map { date in
            let pm = computePortfolioMetrics(funds, asOfDate: date)
            return GainDataPoint(
                id: date, date: date,
                realized: pm.totalRealizedGains,
                unrealized: pm.totalUnrealizedGains,
                liquid: pm.totalGainUsd
            )
        }
    }

    var body: some View {
        let data = points
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gain ($)")
                    .font(.headline).foregroundColor(.textPrimary)
                Spacer()
                if let last = data.last {
                    HStack(spacing: 8) {
                        LegendDot(color: .mint, label: "R: \(formatCurrency(last.realized))")
                        LegendDot(color: .orange, label: "U: \(formatCurrency(last.unrealized))")
                        LegendDot(color: .blue, label: "L: \(formatCurrency(last.liquid))")
                    }
                }
            }

            if data.count >= 2 {
                Chart(data) { pt in
                    LineMark(x: .value("Date", pt.date), y: .value("Realized", pt.realized))
                        .foregroundStyle(by: .value("Type", "Realized"))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", pt.date), y: .value("Unrealized", pt.unrealized))
                        .foregroundStyle(by: .value("Type", "Unrealized"))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", pt.date), y: .value("Liquid", pt.liquid))
                        .foregroundStyle(by: .value("Type", "Liquid"))
                        .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Unrealized": Color.orange, "Liquid": Color.blue])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let str = value.as(String.self) {
                                Text(String(str.suffix(5)))
                                    .font(.caption2).foregroundColor(.textMuted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatCurrency(v))
                                    .font(.caption2).foregroundColor(.textMuted)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 180)
            } else {
                Text("Not enough data for chart")
                    .font(.caption).foregroundColor(.textMuted)
                    .frame(height: 180)
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

// MARK: - Legend Dot Helper

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
