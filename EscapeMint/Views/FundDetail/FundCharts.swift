import SwiftUI
import Charts

// MARK: - Shared Chart Placeholders

/// Loading placeholder sized to the standard chart frame. Replaces 10 inline copies of
/// `EMChartLoadingPlaceholder()` across
/// `FundCharts`, `DerivativesCharts`, and `FundDetailView`.
struct EMChartLoadingPlaceholder: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .frame(height: Layout.chartFrameHeight)
    }
}

// MARK: - Async Chart Data Loading

extension View {
    /// Loads a chart series for a fund: serve from `ChartCache` if present, otherwise
    /// compute off the main actor, honor cancellation, cache the result, and publish
    /// it into `points`. Keyed by `fundId`+`entryCount` so it reloads when either
    /// changes; clears `points` when the fund switches. Replaces four identical
    /// `.task(id:)` blocks across the per-fund charts.
    func chartDataTask<T: Sendable>(
        fundId: String,
        entryCount: Int,
        points: Binding<[T]?>,
        priority: TaskPriority = .utility,
        compute: @escaping @Sendable () -> [T]
    ) -> some View {
        self
            .task(id: "\(fundId)-\(entryCount)") {
                if let cached = ChartCache.shared.cachedChartPoints(type: T.self, fundId: fundId, entryCount: entryCount) {
                    points.wrappedValue = cached
                } else {
                    let computed = await Task.detached(priority: priority, operation: compute).value
                    guard !Task.isCancelled else { return }
                    ChartCache.shared.cacheChartPoints(computed, type: T.self, fundId: fundId, entryCount: entryCount)
                    points.wrappedValue = computed
                }
            }
            .onChange(of: fundId) { _, _ in points.wrappedValue = nil }
    }
}

// MARK: - Chart Hover Overlay

struct ChartTooltipCard: View {
    let date: String
    let lines: [(label: String, value: String, color: Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatTooltipDate(date))
                .font(.caption2).fontWeight(.medium).foregroundColor(.textPrimary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 3) {
                    Circle().fill(line.color).frame(width: 5, height: 5)
                    Text("\(line.label):")
                        .font(.system(size: 9)).foregroundColor(.textMuted)
                    Text(line.value)
                        .font(.system(size: 9, weight: .medium)).foregroundColor(line.color)
                }
            }
        }
        .padding(6)
        .background(Color.bgCard)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.textMuted.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

struct ChartHoverLine: Shape {
    let xPos: CGFloat
    let yStart: CGFloat
    let yEnd: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: xPos, y: yStart))
        path.addLine(to: CGPoint(x: xPos, y: yEnd))
        return path
    }
}

func chartHoverOverlay<T: DateIdentifiable>(
    proxy: ChartProxy,
    entries: [T],
    hoverIndex: Binding<Int?>,
    tooltipLines: @escaping (T) -> [(label: String, value: String, color: Color)]
) -> some View {
    GeometryReader { geo in
        if let plotFrame = proxy.plotFrame {
            let frame = geo[plotFrame]

            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let x = loc.x - frame.origin.x
                        let frac = max(0, min(1, x / frame.width))
                        hoverIndex.wrappedValue = Int(round(frac * Double(entries.count - 1)))
                    case .ended:
                        hoverIndex.wrappedValue = nil
                    @unknown default:
                        hoverIndex.wrappedValue = nil
                    }
                }
                .overlay {
                    if let idx = hoverIndex.wrappedValue,
                       idx >= 0, idx < entries.count {
                        let entry = entries[idx]
                        let xFrac = Double(idx) / Double(max(1, entries.count - 1))
                        let xPos = frame.origin.x + xFrac * frame.width

                        ChartHoverLine(xPos: xPos, yStart: frame.origin.y, yEnd: frame.origin.y + frame.height)
                            .stroke(Color.textMuted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        ChartTooltipCard(date: entry.date, lines: tooltipLines(entry))
                            .position(
                                x: xPos > frame.midX ? xPos - 70 : xPos + 70,
                                y: frame.origin.y + 40
                            )
                    }
                }
        }
    }
}

// MARK: - APY Auto-Range

/// Auto-clamp APY charts when outliers would make the chart unreadable.
/// If most values fit within -100%...+100% but outliers push beyond, clamp to that range.
private func apyAutoBounds(_ values: [Double]) -> ChartBounds? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    // Use 5th/95th percentile to detect outliers
    let p5 = sorted[max(0, Int(Double(sorted.count) * 0.05))]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let dataMin = sorted.first!
    let dataMax = sorted.last!
    // If the full range is within -1...1 (-100%...+100%), no clamping needed
    guard dataMin < -1.0 || dataMax > 1.0 else { return nil }
    // Clamp with 10% padding in the correct direction (toward more extreme, not toward zero)
    let clampMin = max(p5 - abs(p5) * 0.1, -1.0)
    let clampMax = min(p95 + abs(p95) * 0.1, 1.0)
    return ChartBounds(yMin: min(clampMin, -0.1), yMax: max(clampMax, 0.1))
}

// MARK: - Chart Views

struct ValueChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    let fundId: String
    @State private var points: [ValuePoint]?
    @State private var hoverIndex: Int?

    var body: some View {
        EMChartCard(title: "Value & Allocation") {
            if let last = points?.last {
                let d = config.dollarDec
                LegendDot(color: .mint, label: "Value \(formatCurrency(last.value, decimals: d))")
                LegendDot(color: .purple, label: "Invested \(formatCurrency(last.invested, decimals: d))")
                LegendDot(color: .green, label: "Target \(formatCurrency(last.target, decimals: d))")
            }
        } chart: {
            if let points {
                Chart {
                    ForEach(points) { pt in
                        let d = pt.dateValue
                        AreaMark(x: .value("Date", d), y: .value("Invested", pt.invested))
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [Color.purple.opacity(0.2), Color.purple.opacity(0.0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Value", pt.value))
                            .foregroundStyle(by: .value("Type", "Value"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Invested", pt.invested))
                            .foregroundStyle(by: .value("Type", "Invested"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Target", pt.target))
                            .foregroundStyle(by: .value("Type", "Target"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                }
                .chartForegroundStyleScale(["Value": Color.mint, "Invested": Color.purple, "Target": Color.green])
                .chartXAxis { emDateAxisTemporal(spanDays: chartSpanDays(points)) }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    let d = config.dollarDec
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Value", value: formatCurrency(pt.value, decimals: d), color: .mint),
                            (label: "Invested", value: formatCurrency(pt.invested, decimals: d), color: .purple),
                            (label: "Target", value: formatCurrency(pt.target, decimals: d), color: .green),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                EMChartLoadingPlaceholder()
            }
        }
        .chartDataTask(fundId: fundId, entryCount: entries.count, points: $points) { [entries, config] in
            computeValuePoints(entries: entries, config: config)
        }
    }
}

struct PLChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    let fundId: String
    @State private var points: [PLPoint]?
    @State private var hoverIndex: Int?

    private var bounds: ChartBounds? { config.chart_bounds?["pnl"] }

    var body: some View {
        EMChartCard(title: "P&L Over Time") {
            if let last = points?.last {
                let d = config.dollarDec
                LegendDot(color: .mint, label: "R: \(formatCurrency(last.realized, decimals: d))")
                LegendDot(color: .blue, label: "L: \(formatCurrency(last.liquid, decimals: d))")
            }
            ChartBoundsButton(fundId: fundId, boundsKey: "pnl", isPercent: false, bounds: bounds)
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realized < 0 || $0.liquid < 0 }
                let allValues = points.flatMap { [$0.realized, $0.liquid] }
                let domain = chartYDomain(bounds, points: allValues)
                Chart {
                    ForEach(points) { pt in
                        let d = pt.dateValue
                        AreaMark(
                            x: .value("Date", d),
                            yStart: .value("Baseline", domain.clamping(0)),
                            yEnd: .value("Liquid", domain.clamping(pt.liquid))
                        )
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Realized", domain.clamping(pt.realized)))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Liquid", domain.clamping(pt.liquid)))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal(spanDays: chartSpanDays(points)) }
                .chartYAxis { emCurrencyAxis() }
                .chartYScale(domain: domain)
                .chartPlotStyle { $0.clipped() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    let d = config.dollarDec
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Realized", value: formatCurrency(pt.realized, decimals: d), color: .mint),
                            (label: "Liquid", value: formatCurrency(pt.liquid, decimals: d), color: .blue),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                EMChartLoadingPlaceholder()
            }
        }
        .chartDataTask(fundId: fundId, entryCount: entries.count, points: $points, priority: .userInitiated) { [entries, config] in
            computePLPoints(entries: entries, config: config)
        }
    }
}

struct APYChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    let fundId: String
    @State private var points: [APYPoint]?
    @State private var hoverIndex: Int?

    private var bounds: ChartBounds? { config.chart_bounds?["apy"] }

    var body: some View {
        EMChartCard(title: "APY Over Time") {
            if let last = points?.last {
                LegendDot(color: .mint, label: "R: \(formatPercent(last.realizedAPY))")
                LegendDot(color: .blue, label: "L: \(formatPercent(last.liquidAPY))")
            }
            ChartBoundsButton(fundId: fundId, boundsKey: "apy", isPercent: true, bounds: bounds)
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realizedAPY < 0 || $0.liquidAPY < 0 }
                let allValues = points.flatMap { [$0.realizedAPY, $0.liquidAPY] }
                let effectiveBounds = bounds ?? apyAutoBounds(allValues)
                let domain = chartYDomain(effectiveBounds, points: allValues)
                Chart {
                    ForEach(points) { pt in
                        let d = pt.dateValue
                        // Clamp into the domain: early-life APYs can annualize to
                        // absurd values; saturate at the edge (tooltip shows truth).
                        let rAPY = domain.clamping(pt.realizedAPY)
                        let lAPY = domain.clamping(pt.liquidAPY)
                        AreaMark(x: .value("Date", d), y: .value("L.APY", lAPY))
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("R.APY", rAPY))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("L.APY", lAPY))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal(spanDays: chartSpanDays(points)) }
                .chartYAxis { emPercentAxis() }
                .chartYScale(domain: domain)
                .chartPlotStyle { $0.clipped() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Realized", value: formatPercent(pt.realizedAPY), color: .mint),
                            (label: "Liquid", value: formatPercent(pt.liquidAPY), color: .blue),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                EMChartLoadingPlaceholder()
            }
        }
        .chartDataTask(fundId: fundId, entryCount: entries.count, points: $points) { [entries, config] in
            computeAPYPoints(entries: entries, config: config)
        }
    }
}

struct CapturedProfitChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    let fundId: String
    @State private var points: [ProfitPoint]?
    @State private var hoverIndex: Int?

    var body: some View {
        let pts = points ?? []
        let last = pts.last
        let hasExtracted = (last?.cumExtracted ?? 0) > 0
        let hasDividends = (last?.cumDividend ?? 0) > 0
        let hasInterest = (last?.cumInterest ?? 0) > 0

        EMChartCard(title: "Captured Profit") {
            if let last {
                let dd = config.dollarDec
                if hasExtracted {
                    LegendDot(color: .mint, label: "Extracted \(formatCurrency(last.cumExtracted, decimals: dd))")
                }
                if hasDividends {
                    LegendDot(color: .green, label: "Div: \(formatCurrency(last.cumDividend, decimals: dd))")
                }
                if hasInterest {
                    LegendDot(color: .yellow, label: "Int: \(formatCurrency(last.cumInterest, decimals: dd))")
                }
            }
        } chart: {
            if let points {
                Chart(points) { pt in
                    let d = pt.dateValue
                    AreaMark(x: .value("Date", d), y: .value("Total", pt.total))
                        .foregroundStyle(Color.mint.opacity(0.15))
                        .interpolationMethod(.monotone)
                    if hasExtracted {
                        LineMark(x: .value("Date", d), y: .value("Extracted", pt.cumExtracted))
                            .foregroundStyle(by: .value("Type", "Extracted"))
                            .interpolationMethod(.monotone)
                    }
                    if hasDividends {
                        LineMark(x: .value("Date", d), y: .value("Dividends", pt.cumDividend))
                            .foregroundStyle(by: .value("Type", "Dividends"))
                            .interpolationMethod(.monotone)
                    }
                    if hasInterest {
                        LineMark(x: .value("Date", d), y: .value("Interest", pt.cumInterest))
                            .foregroundStyle(by: .value("Type", "Interest"))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale(["Extracted": Color.mint, "Dividends": Color.green, "Interest": Color.yellow])
                .chartXAxis { emDateAxisTemporal(spanDays: chartSpanDays(points)) }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    let dd = config.dollarDec
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        var lines: [(label: String, value: String, color: Color)] = []
                        if hasExtracted { lines.append((label: "Extracted", value: formatCurrency(pt.cumExtracted, decimals: dd), color: .mint)) }
                        if hasDividends { lines.append((label: "Dividends", value: formatCurrency(pt.cumDividend, decimals: dd), color: .green)) }
                        if hasInterest { lines.append((label: "Interest", value: formatCurrency(pt.cumInterest, decimals: dd), color: .yellow)) }
                        return lines
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                EMChartLoadingPlaceholder()
            }
        }
        .chartDataTask(fundId: fundId, entryCount: entries.count, points: $points) { [entries, config] in
            computeProfitPoints(entries: entries, config: config)
        }
    }
}

// MARK: - Chart Axis Builders
// Date formatters (isoDateFormatter, shortDateFormatter) and format helpers
// (formatDateLabel, formatTooltipDate) are in Converters.swift

/// Date axis with span-aware labels: histories under ~6 months label ticks by day
/// ("May 18") so short ranges don't repeat the same month label on every tick;
/// longer (or unknown) spans keep month labels ("May '26").
func emDateAxisTemporal(spanDays: Int? = nil) -> some AxisContent {
    let formatter = (spanDays ?? Int.max) <= 180 ? monthDayFormatter : shortDateFormatter
    return AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisValueLabel {
            if let date = value.as(Date.self) {
                Text(formatter.string(from: date))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

/// Days between the first and last point of a chart series — feeds the span-aware
/// date axis. Nil (month labels) when there are fewer than two points.
func chartSpanDays<T: DateIdentifiable>(_ points: [T]) -> Int? {
    guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
    return daysBetween(first.date, last.date)
}

@AxisContentBuilder
func emCurrencyAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatCurrencyCompact(v))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

@AxisContentBuilder
func emPercentAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatPercentCompact(v))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

/// Trailing leverage axis ("3.0x") drawn in green with cleared grid lines, for the
/// overlaid leverage scale in the Capital & Leverage chart.
@AxisContentBuilder
func emLeverageAxis() -> some AxisContent {
    AxisMarks(position: .trailing) { value in
        AxisGridLine().foregroundStyle(.clear)
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text("\(v, specifier: "%.1f")x")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
    }
}

// MARK: - Zero Reference Line

@ChartContentBuilder
func emZeroLine() -> some ChartContent {
    RuleMark(y: .value("Zero", 0))
        .foregroundStyle(Color.textMuted.opacity(0.4))
        .lineStyle(StrokeStyle(dash: [4, 4]))
}
