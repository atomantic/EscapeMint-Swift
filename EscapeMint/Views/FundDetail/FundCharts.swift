import SwiftUI
import Charts

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

struct PLPoint: Identifiable {
    let id: String
    let date: String
    let realized: Double
    let liquid: Double
}

struct APYPoint: Identifiable {
    let id: String
    let date: String
    let realizedAPY: Double
    let liquidAPY: Double
}

struct ProfitPoint: Identifiable {
    let id: String
    let date: String
    let cumDividend: Double
    let cumInterest: Double
    let cumExtracted: Double
    var total: Double { cumDividend + cumInterest + cumExtracted }
}

struct ValuePoint: Identifiable {
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
    let sampled = sampleArray(entries)
    return sampled.map { entry in
        let prior = entries.filter { $0.date <= entry.date }
        let trades = entriesToTrades(prior)
        let cashflows = entriesToCashFlows(prior)
        let dividends = entriesToDividends(prior)
        let expenses = entriesToExpenses(prior)
        let state = computeFundState(config: cc, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: entry.value, asOfDate: entry.date)
        return PLPoint(id: entry.date, date: entry.date, realized: state.realizedGainsUsd, liquid: state.gainUsd + state.realizedGainsUsd)
    }
}

func computeAPYPoints(entries: [FundEntry], config: FundConfig) -> [APYPoint] {
    // Use active status for chart computation — closed funds return zeros from computeFundState
    let cc = chartConfig(config)
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

// MARK: - Chart Views

struct ValueChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    let fundId: String
    @State private var points: [ValuePoint]?

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

    var body: some View {
        EMChartCard(title: "P&L Over Time") {
            if let last = points?.last {
                LegendDot(color: .mint, label: "R: \(formatCurrency(last.realized))")
                LegendDot(color: .blue, label: "L: \(formatCurrency(last.liquid))")
            }
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realized < 0 || $0.liquid < 0 }
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
                .chartLegend(.hidden)
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

    var body: some View {
        EMChartCard(title: "APY Over Time") {
            if let last = points?.last {
                LegendDot(color: .mint, label: "R: \(formatPercent(last.realizedAPY))")
                LegendDot(color: .blue, label: "L: \(formatPercent(last.liquidAPY))")
            }
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realizedAPY < 0 || $0.liquidAPY < 0 }
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
                .chartLegend(.hidden)
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
