import SwiftUI
import Charts

// MARK: - DateIdentifiable Protocol

protocol DateIdentifiable: Identifiable {
    var date: String { get }
    var dateValue: Date { get }
}

extension DateIdentifiable {
    var dateValue: Date {
        isoDateFormatter.date(from: date) ?? .distantPast
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

// MARK: - Sampling

func sampleArray<T>(_ items: [T], maxPoints: Int = 60) -> [T] {
    let step = max(1, items.count / maxPoints)
    return items.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == items.count - 1 }
        .map(\.element)
}

// MARK: - Stat Box

struct StatBox: View {
    let label: String
    let value: String
    var color: Color = .textPrimary
    var showCard: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.semibold).foregroundColor(color)
        }
        .frame(maxWidth: showCard ? .infinity : nil, alignment: .leading)
        .padding(showCard ? 10 : 0)
        .background(showCard ? Color.bgCard : .clear)
        .cornerRadius(showCard ? 8 : 0)
    }
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

// MARK: - Chart Computation Helpers

private func chartConfig(_ config: FundConfig) -> FundConfig {
    var c = config
    c.status = .active
    return c
}

func computePLPoints(entries: [FundEntry], config: FundConfig) -> [PLPoint] {
    // Use active status for chart computation — closed funds return zeros from computeFundState
    let cc = chartConfig(config)
    let isCash = isCashFund(config.fund_type)
    let sampled = sampleArray(entries)
    return sampled.map { entry in
        let prior = entries.filter { $0.date <= entry.date }
        let trades = entriesToTrades(prior)
        let cashflows = entriesToCashFlows(prior)
        let dividends = entriesToDividends(prior)
        let expenses = entriesToExpenses(prior)
        let state = computeFundState(config: cc, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: entry.value, asOfDate: entry.date)
        // Cash funds: unrealized=0, liquid=realized (no double-counting)
        let liquid = isCash ? state.realizedGainsUsd : state.gainUsd + state.realizedGainsUsd
        return PLPoint(id: entry.date, date: entry.date, realized: state.realizedGainsUsd, liquid: liquid)
    }
}

func computeAPYPoints(entries: [FundEntry], config: FundConfig) -> [APYPoint] {
    let cc = chartConfig(config)
    let isCash = isCashFund(config.fund_type)

    if isCash {
        return computeCashAPYPoints(entries: entries, config: cc)
    }

    let sampled = sampleArray(entries)
    return sampled.map { entry in
        let prior = entries.filter { $0.date <= entry.date }
        let trades = entriesToTrades(prior)
        let cashflows = entriesToCashFlows(prior)
        let dividends = entriesToDividends(prior)
        let expenses = entriesToExpenses(prior)
        let startDate = getFundStartDate(prior)
        let days = max(1, daysBetween(startDate, entry.date))
        let state = computeFundState(config: cc, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: entry.value, asOfDate: entry.date)
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: startDate, asOfDate: entry.date)
        let basis = twfs > 0 ? twfs : state.startInputUsd
        let rAPY = computeLinearAPY(state.realizedGainsUsd, basis, days)
        let lGain = state.gainUsd + state.realizedGainsUsd
        let lAPY = computeLinearAPY(lGain, basis, days)
        return APYPoint(id: entry.date, date: entry.date, realizedAPY: rAPY, liquidAPY: lAPY)
    }
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
    for entry in entries {
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
        let apy = abs(realized) >= 0.01 ? computeLinearAPY(realized, basis, days) : 0
        all.append(APYPoint(id: entry.date, date: entry.date, realizedAPY: apy, liquidAPY: apy))
    }
    return sampleArray(all)
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
    let all = entries.map { entry -> ProfitPoint in
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
    return sampleArray(all)
}

func computeValuePoints(entries: [FundEntry], config: FundConfig) -> [ValuePoint] {
    let isAccumulate = config.accumulate == true
    var totalBuys = 0.0
    var totalSells = 0.0
    var sumShares = 0.0

    // Single pass: compute net invested per entry
    let allWithInvested: [(entry: FundEntry, invested: Double)] = entries.map { entry in
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

    // Sample, then compute target per sampled point
    let sampled = sampleArray(allWithInvested)

    let cc = chartConfig(config)

    return sampled.map { item in
        let prior = entries.filter { $0.date <= item.entry.date }
        let trades = entriesToTrades(prior)
        let target = computeExpectedTarget(config: cc, trades: trades, asOfDate: item.entry.date)
        return ValuePoint(id: item.entry.date, date: item.entry.date, value: item.entry.value, invested: item.invested, target: target)
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
                LegendDot(color: .mint, label: "Value \(formatCurrency(last.value))")
                LegendDot(color: .purple, label: "Invested \(formatCurrency(last.invested))")
                LegendDot(color: .green, label: "Target \(formatCurrency(last.target))")
            }
        } chart: {
            if let points {
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
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
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Value", value: formatCurrency(pt.value), color: .mint),
                            (label: "Invested", value: formatCurrency(pt.invested), color: .purple),
                            (label: "Target", value: formatCurrency(pt.target), color: .green),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
        .task(id: "\(fundId)-\(entries.count)") {
            if let cached = ViewCache.shared.cachedChartPoints(type: ValuePoint.self, fundId: fundId, entryCount: entries.count) {
                points = cached
            } else {
                let e = entries, c = config
                let computed = await Task.detached(priority: .utility) {
                    computeValuePoints(entries: e, config: c)
                }.value
                guard !Task.isCancelled else { return }
                ViewCache.shared.cacheChartPoints(computed, type: ValuePoint.self, fundId: fundId, entryCount: entries.count)
                points = computed
            }
        }
        .onChange(of: fundId) { _, _ in points = nil }
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
                LegendDot(color: .mint, label: "R: \(formatCurrency(last.realized))")
                LegendDot(color: .blue, label: "L: \(formatCurrency(last.liquid))")
            }
            ChartBoundsButton(fundId: fundId, boundsKey: "pnl", isPercent: false, bounds: bounds)
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realized < 0 || $0.liquid < 0 }
                let allValues = points.flatMap { [$0.realized, $0.liquid] }
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        AreaMark(x: .value("Date", d), y: .value("Liquid", pt.liquid))
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Realized", pt.realized))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Liquid", pt.liquid))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartYScale(domain: chartYDomain(bounds, points: allValues))
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Realized", value: formatCurrency(pt.realized), color: .mint),
                            (label: "Liquid", value: formatCurrency(pt.liquid), color: .blue),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
        .task(id: "\(fundId)-\(entries.count)") {
            if let cached = ViewCache.shared.cachedChartPoints(type: PLPoint.self, fundId: fundId, entryCount: entries.count) {
                points = cached
            } else {
                let e = entries, c = config
                let computed = await Task.detached(priority: .utility) {
                    computePLPoints(entries: e, config: c)
                }.value
                guard !Task.isCancelled else { return }
                ViewCache.shared.cacheChartPoints(computed, type: PLPoint.self, fundId: fundId, entryCount: entries.count)
                points = computed
            }
        }
        .onChange(of: fundId) { _, _ in points = nil }
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
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
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
                .chartYScale(domain: chartYDomain(effectiveBounds, points: allValues))
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
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
        .task(id: "\(fundId)-\(entries.count)") {
            if let cached = ViewCache.shared.cachedChartPoints(type: APYPoint.self, fundId: fundId, entryCount: entries.count) {
                points = cached
            } else {
                let e = entries, c = config
                let computed = await Task.detached(priority: .utility) {
                    computeAPYPoints(entries: e, config: c)
                }.value
                guard !Task.isCancelled else { return }
                ViewCache.shared.cacheChartPoints(computed, type: APYPoint.self, fundId: fundId, entryCount: entries.count)
                points = computed
            }
        }
        .onChange(of: fundId) { _, _ in points = nil }
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
                if hasExtracted {
                    LegendDot(color: .mint, label: "Extracted \(formatCurrency(last.cumExtracted))")
                }
                if hasDividends {
                    LegendDot(color: .green, label: "Div: \(formatCurrency(last.cumDividend))")
                }
                if hasInterest {
                    LegendDot(color: .yellow, label: "Int: \(formatCurrency(last.cumInterest))")
                }
            }
        } chart: {
            if let points {
                Chart(points) { pt in
                    let d = isoDateFormatter.date(from: pt.date) ?? Date()
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
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        var lines: [(label: String, value: String, color: Color)] = []
                        if hasExtracted { lines.append((label: "Extracted", value: formatCurrency(pt.cumExtracted), color: .mint)) }
                        if hasDividends { lines.append((label: "Dividends", value: formatCurrency(pt.cumDividend), color: .green)) }
                        if hasInterest { lines.append((label: "Interest", value: formatCurrency(pt.cumInterest), color: .yellow)) }
                        return lines
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
        .task(id: "\(fundId)-\(entries.count)") {
            if let cached = ViewCache.shared.cachedChartPoints(type: ProfitPoint.self, fundId: fundId, entryCount: entries.count) {
                points = cached
            } else {
                let e = entries, c = config
                let computed = await Task.detached(priority: .utility) {
                    computeProfitPoints(entries: e, config: c)
                }.value
                guard !Task.isCancelled else { return }
                ViewCache.shared.cacheChartPoints(computed, type: ProfitPoint.self, fundId: fundId, entryCount: entries.count)
                points = computed
            }
        }
        .onChange(of: fundId) { _, _ in points = nil }
    }
}

// MARK: - Chart Axis Builders
// Date formatters (isoDateFormatter, shortDateFormatter) and format helpers
// (formatDateLabel, formatTooltipDate) are in Converters.swift

@AxisContentBuilder
func emDateAxisTemporal() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisValueLabel {
            if let date = value.as(Date.self) {
                Text(shortDateFormatter.string(from: date))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
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
                Text(formatPercent(v))
                    .font(.caption2).foregroundColor(.textMuted)
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
