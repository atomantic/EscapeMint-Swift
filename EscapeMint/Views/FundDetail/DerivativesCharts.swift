import SwiftUI
import Charts

// MARK: - Derivatives Chart Data

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

func computeDerivativesChartData(entries: [FundEntry], config: FundConfig) -> [DerivativesChartPoint] {
    let cm = config.contract_multiplier ?? 0.01
    let imr = config.initial_margin_rate ?? 0.25
    let mmr = config.maintenance_margin_rate ?? 0.20
    let startDate = entries.first?.date ?? ""

    var position = 0.0
    var marginBalance = 0.0
    var lastTradePrice = 0.0 // per-contract price for unrealized estimation
    var cumFunding = 0.0
    var cumInterest = 0.0
    var cumRebates = 0.0
    var cumFees = 0.0
    var cumRealized = 0.0
    var totalBuyCost = 0.0
    var totalBuyContracts = 0.0

    let all = entries.map { entry -> DerivativesChartPoint in
        let action = entry.action
        let contracts = entry.contracts ?? 0
        let amount = entry.amount ?? 0
        let fee = entry.fee ?? 0
        let tradePrice = entry.price ?? 0

        switch action {
        case .DEPOSIT:
            marginBalance += abs(amount)
        case .WITHDRAW:
            marginBalance -= abs(amount)
        case .BUY:
            position += contracts
            totalBuyCost += abs(amount)
            totalBuyContracts += contracts
            let absFee = abs(fee)
            cumFees += absFee
            marginBalance -= absFee
            if tradePrice > 0 { lastTradePrice = tradePrice }
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
        case .FUNDING:
            cumFunding += amount
            marginBalance += amount
        case .INTEREST:
            cumInterest += amount
            marginBalance += amount
        case .REBATE:
            cumRebates += amount
            marginBalance += amount
        case .FEE:
            let absFee = abs(amount)
            cumFees += absFee
            marginBalance -= absFee
        default:
            break
        }

        // Use TSV values if available, otherwise compute from trade data
        let avgCostPerContract = totalBuyContracts > 0 ? totalBuyCost / totalBuyContracts : 0
        let avgEntry = entry.entry_price ?? (position > 0 ? avgCostPerContract / cm : 0)
        let costBasis = totalBuyCost
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
            return (costBasis - marginBalance) / (notionalSize * (1.0 - mmr))
        }()

        // Margin balance: prefer TSV cash if available
        let effectiveMarginBalance = entry.cash ?? marginBalance

        let capturedProfit = cumRealized + cumFunding + cumInterest + cumRebates - cumFees
        let liquidPL = capturedProfit + unrealized

        let days = Double(max(1, daysBetween(startDate, entry.date)))
        let capitalBase = max(1.0, effectiveMarginBalance - liquidPL)
        let realizedAPY = capturedProfit / capitalBase * (365.0 / days)
        let liquidAPY = liquidPL / capitalBase * (365.0 / days)

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
            sumRealized: cumRealized,
            sumFunding: cumFunding,
            sumInterest: cumInterest,
            sumRebates: cumRebates,
            sumFees: cumFees
        )
    }

    // Aggregate by date — keep only the last entry per date (end-of-day snapshot)
    var byDate: [String: DerivativesChartPoint] = [:]
    var dateOrder: [String] = []
    for pt in all {
        if byDate[pt.date] == nil { dateOrder.append(pt.date) }
        byDate[pt.date] = pt
    }
    let aggregated = dateOrder.compactMap { byDate[$0] }
    return sampleArray(aggregated)
}

// MARK: - State Cards

private struct StateCardContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current State")
                .font(.headline).foregroundColor(.textPrimary)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .cardStyle()
    }
}

struct ClosedFundStateCard: View {
    let closedMetrics: ClosedFundMetrics

    var body: some View {
        let cm = closedMetrics
        StateCardContainer {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    StatBox(label: "Total Invested", value: formatCurrencyFull(cm.totalInvestedUsd), showCard: false)
                    StatBox(label: "Total Returned", value: formatCurrencyFull(cm.totalReturnedUsd), showCard: false)
                }
                GridRow {
                    StatBox(label: "Net Gain/Loss", value: "\(formatCurrencyFull(cm.netGainUsd)) (\(formatPercent(cm.returnPct)))", color: cm.netGainUsd >= 0 ? .mint : .red, showCard: false)
                    StatBox(label: "Annualized Return", value: formatPercent(cm.apy), color: cm.apy > 0 ? .mint : .red, showCard: false)
                }
                GridRow {
                    StatBox(label: "Dividends", value: formatCurrencyFull(cm.totalDividendsUsd), showCard: false)
                    StatBox(label: "Cash Interest", value: formatCurrencyFull(cm.totalCashInterestUsd), showCard: false)
                }
                GridRow {
                    StatBox(label: "Duration", value: "\(cm.durationDays) days", showCard: false)
                    StatBox(label: "Expenses", value: formatCurrencyFull(-cm.totalExpensesUsd), color: cm.totalExpensesUsd > 0 ? .red : .white, showCard: false)
                }
            }
        }
    }
}

struct ActiveFundStateCard: View {
    let state: FundState
    let summary: FundSummary

    var body: some View {
        StateCardContainer {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    StatBox(label: "Invested", value: formatCurrencyFull(state.startInputUsd), showCard: false)
                    StatBox(label: "Asset Value", value: formatCurrencyFull(summary.currentValue), showCard: false)
                }
                GridRow {
                    StatBox(label: "Unrealized", value: "\(summary.unrealizedGains >= 0 ? "+" : "")\(formatCurrencyFull(summary.unrealizedGains))", color: summary.unrealizedGains >= 0 ? .mint : .red, showCard: false)
                    StatBox(label: "Cash", value: formatCurrencyFull(state.cashAvailableUsd), showCard: false)
                }
                GridRow {
                    StatBox(label: "Realized", value: formatCurrencyFull(state.realizedGainsUsd), color: state.realizedGainsUsd > 0 ? .mint : .textPrimary, showCard: false)
                    StatBox(label: "Realized APY", value: formatPercent(summary.realizedAPY), color: summary.realizedAPY > 0 ? .mint : .red, showCard: false)
                }
                GridRow {
                    StatBox(label: "Liquid P&L", value: formatCurrencyFull(summary.liquidGain), color: summary.liquidGain >= 0 ? .mint : .red, showCard: false)
                    StatBox(label: "Liquid APY", value: formatPercent(summary.liquidAPY), color: summary.liquidAPY > 0 ? .mint : .red, showCard: false)
                }
            }
        }
    }
}

// MARK: - Chart Bounds Editor

struct ChartBoundsButton: View {
    let fundId: String
    let boundsKey: String
    let isPercent: Bool
    var bounds: ChartBounds?
    @State private var showPopover = false
    @State private var minText = ""
    @State private var maxText = ""

    private var hasCustomBounds: Bool { bounds?.yMin != nil || bounds?.yMax != nil }

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .foregroundColor(hasCustomBounds ? .mint : .textMuted)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Y-Axis Bounds").font(.caption).fontWeight(.semibold).foregroundColor(.textMuted)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Min").font(.caption2).foregroundColor(.textMuted)
                        TextField("Auto", text: $minText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max").font(.caption2).foregroundColor(.textMuted)
                        TextField("Auto", text: $maxText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .font(.caption)
                    }
                }
                HStack {
                    Button("Clear") {
                        saveBounds(ChartBounds())
                        showPopover = false
                    }
                    .font(.caption).foregroundColor(.red)
                    Spacer()
                    Button("Apply") {
                        let yMin = Double(minText).map { isPercent ? $0 / 100.0 : $0 }
                        let yMax = Double(maxText).map { isPercent ? $0 / 100.0 : $0 }
                        saveBounds(ChartBounds(yMin: yMin, yMax: yMax))
                        showPopover = false
                    }
                    .font(.caption).fontWeight(.medium).foregroundColor(.mint)
                }
            }
            .padding(12)
            .frame(minWidth: 220)
            .onAppear {
                if isPercent {
                    minText = bounds?.yMin.map { String(format: "%.1f", $0 * 100) } ?? ""
                    maxText = bounds?.yMax.map { String(format: "%.1f", $0 * 100) } ?? ""
                } else {
                    minText = bounds?.yMin.map { String(format: "%.0f", $0) } ?? ""
                    maxText = bounds?.yMax.map { String(format: "%.0f", $0) } ?? ""
                }
            }
        }
    }

    private func saveBounds(_ newBounds: ChartBounds) {
        let store = FundDataStore.shared
        guard var config = store.fund(byId: fundId)?.config else { return }
        var allBounds = config.chart_bounds ?? [:]
        if newBounds.isEmpty {
            allBounds.removeValue(forKey: boundsKey)
        } else {
            allBounds[boundsKey] = newBounds
        }
        config.chart_bounds = allBounds.isEmpty ? nil : allBounds
        Task { await store.updateConfig(fundId: fundId, config: config) }
    }
}

/// Compute a Y-axis domain from optional bounds, falling back to auto-range from data values
func chartYDomain(_ bounds: ChartBounds?, points values: [Double]) -> ClosedRange<Double> {
    let yMin = bounds?.yMin ?? (values.min() ?? 0)
    let yMax = bounds?.yMax ?? (values.max() ?? 1)
    guard yMin < yMax else { return 0...1 }
    return yMin...yMax
}

// MARK: - P&L Chart (Derivatives)

struct DerivativesPLChart: View {
    let points: [DerivativesChartPoint]
    var fundId: String = ""
    var bounds: ChartBounds?
    @State private var hoverIndex: Int?

    var body: some View {
        EMChartCard(title: "P&L") {
            LegendDot(color: .orange, label: "Liquid")
            LegendDot(color: .mint, label: "Realized")
            if !fundId.isEmpty { ChartBoundsButton(fundId: fundId, boundsKey: "pnl", isPercent: false, bounds: bounds) }
        } chart: {
            if !points.isEmpty {
                let hasNeg = points.contains { $0.capturedProfit < 0 || $0.liquidPL < 0 }
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        LineMark(x: .value("Date", d), y: .value("Liquid", pt.liquidPL))
                            .foregroundStyle(by: .value("Series", "Liquid"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Realized", pt.capturedProfit))
                            .foregroundStyle(by: .value("Series", "Realized"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNeg { emZeroLine() }
                }
                .chartForegroundStyleScale(["Liquid": Color.orange, "Realized": Color.mint])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartYScale(domain: chartYDomain(bounds, points: points.flatMap { [$0.liquidPL, $0.capturedProfit] }))
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Liquid", value: formatCurrency(pt.liquidPL), color: .orange),
                            (label: "Realized", value: formatCurrency(pt.capturedProfit), color: .mint),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
    }
}

// MARK: - APY Chart (Derivatives)

struct DerivativesAPYChart: View {
    let points: [DerivativesChartPoint]
    var fundId: String = ""
    var bounds: ChartBounds?
    @State private var hoverIndex: Int?

    var body: some View {
        EMChartCard(title: "APY") {
            LegendDot(color: .orange, label: "Liquid")
            LegendDot(color: .mint, label: "Realized")
            if !fundId.isEmpty { ChartBoundsButton(fundId: fundId, boundsKey: "apy", isPercent: true, bounds: bounds) }
        } chart: {
            if !points.isEmpty {
                let hasNeg = points.contains { $0.realizedAPY < 0 || $0.liquidAPY < 0 }
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        LineMark(x: .value("Date", d), y: .value("L.APY", pt.liquidAPY))
                            .foregroundStyle(by: .value("Series", "Liquid"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("R.APY", pt.realizedAPY))
                            .foregroundStyle(by: .value("Series", "Realized"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNeg { emZeroLine() }
                }
                .chartForegroundStyleScale(["Liquid": Color.orange, "Realized": Color.mint])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emPercentAxis() }
                .chartYScale(domain: chartYDomain(bounds, points: points.flatMap { [$0.liquidAPY, $0.realizedAPY] }))
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Liquid", value: formatPercent(pt.liquidAPY), color: .orange),
                            (label: "Realized", value: formatPercent(pt.realizedAPY), color: .mint),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
    }
}

// MARK: - Value & Allocation Chart

struct DerivativesValueChart: View {
    let points: [DerivativesChartPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        EMChartCard(title: "Value & Allocation") {
            LegendDot(color: .purple, label: "Notional")
            LegendDot(color: .blue, label: "Cost Basis")
            LegendDot(color: .mint, label: "Position Value")
        } chart: {
            if !points.isEmpty {
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        AreaMark(x: .value("Date", d), y: .value("Notional", pt.costBasis))
                            .foregroundStyle(Color.purple.opacity(0.15))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Notional", pt.costBasis))
                            .foregroundStyle(by: .value("Series", "Notional"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Cost Basis", pt.costBasis))
                            .foregroundStyle(by: .value("Series", "Cost Basis"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                        LineMark(x: .value("Date", d), y: .value("Position Value", pt.positionValue))
                            .foregroundStyle(by: .value("Series", "Position Value"))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale(["Notional": Color.purple, "Cost Basis": Color.blue, "Position Value": Color.mint])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Notional", value: formatCurrency(pt.costBasis), color: .purple),
                            (label: "Cost Basis", value: formatCurrency(pt.costBasis), color: .blue),
                            (label: "Position", value: formatCurrency(pt.positionValue), color: .mint),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
    }
}

// MARK: - Price & Liquidation Chart

struct DerivativesPriceChart: View {
    let points: [DerivativesChartPoint]
    var fundId: String = ""
    var bounds: ChartBounds?
    @State private var hoverIndex: Int?

    var body: some View {
        let withPosition = points.filter { $0.position > 0 && $0.avgEntry > 0 }
        // Clamp liq price: negative means over-collateralized (safe), extreme values aren't useful
        let maxReasonableLiq = (withPosition.map(\.avgEntry).max() ?? 1) * 3
        let clampedPoints = withPosition.map { pt -> (id: String, date: String, avgEntry: Double, liqPrice: Double) in
            let clamped = pt.liqPrice < 0 ? 0 : min(pt.liqPrice, maxReasonableLiq)
            return (id: pt.id, date: pt.date, avgEntry: pt.avgEntry, liqPrice: clamped)
        }
        EMChartCard(title: "Price & Liquidation") {
            LegendDot(color: .orange, label: "Avg Entry")
            LegendDot(color: .mint, label: "Liq Price")
            if !fundId.isEmpty { ChartBoundsButton(fundId: fundId, boundsKey: "derivativesPrice", isPercent: false, bounds: bounds) }
        } chart: {
            if clampedPoints.count >= 2 {
                Chart {
                    ForEach(clampedPoints, id: \.id) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        LineMark(x: .value("Date", d), y: .value("Avg Entry", pt.avgEntry))
                            .foregroundStyle(by: .value("Series", "Avg Entry"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Liq Price", pt.liqPrice))
                            .foregroundStyle(by: .value("Series", "Liq Price"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                    }
                }
                .chartForegroundStyleScale(["Avg Entry": Color.orange, "Liq Price": Color.mint])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartYScale(domain: chartYDomain(bounds, points: clampedPoints.flatMap { [$0.avgEntry, $0.liqPrice] }))
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: withPosition, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Avg Entry", value: formatCurrency(pt.avgEntry), color: .orange),
                            (label: "Liq Price", value: formatCurrency(max(0, pt.liqPrice)), color: .mint),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                Text("Not enough position data")
                    .font(.caption).foregroundColor(.textMuted)
                    .frame(height: Layout.chartFrameHeight)
            }
        }
    }
}

// MARK: - Capital & Leverage Chart

struct DerivativesMarginChart: View {
    let points: [DerivativesChartPoint]
    @State private var hoverIndex: Int?

    private var maxLev: Double { max(5.0, (points.map(\.leverage).max() ?? 5) * 1.2) }

    private var primaryChart: some View {
        Chart {
            ForEach(points) { pt in
                let d = isoDateFormatter.date(from: pt.date) ?? Date()
                AreaMark(x: .value("Date", d), y: .value("Cash", pt.marginBalance))
                    .foregroundStyle(Color.blue.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", d), y: .value("Cash", pt.marginBalance))
                    .foregroundStyle(by: .value("Series", "Cash"))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", d), y: .value("Margin Locked", pt.marginLocked))
                    .foregroundStyle(by: .value("Series", "Margin Locked"))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["Cash": Color.blue, "Margin Locked": Color.orange])
        .chartXAxis { emDateAxisTemporal() }
        .chartYAxis { emCurrencyAxis() }
        .chartLegend(.hidden)
    }

    private var leverageChart: some View {
        Chart {
            ForEach(points) { pt in
                let d = isoDateFormatter.date(from: pt.date) ?? Date()
                LineMark(x: .value("Date", d), y: .value("Leverage", pt.leverage))
                    .foregroundStyle(Color.green)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
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
        .chartYScale(domain: 0...maxLev)
        .chartLegend(.hidden)
        .allowsHitTesting(false)
    }

    private func hoverOverlay() -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let frac = max(0, min(1, loc.x / geo.size.width))
                        hoverIndex = Int(round(frac * Double(points.count - 1)))
                    case .ended:
                        hoverIndex = nil
                    @unknown default:
                        hoverIndex = nil
                    }
                }
                .overlay {
                    if let idx = hoverIndex, idx >= 0, idx < points.count {
                        let pt = points[idx]
                        let xFrac = Double(idx) / Double(max(1, points.count - 1))
                        let xPos = xFrac * geo.size.width

                        ChartHoverLine(xPos: xPos, yStart: 0, yEnd: geo.size.height)
                            .stroke(Color.textMuted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        ChartTooltipCard(date: pt.date, lines: [
                            (label: "Cash", value: formatCurrency(pt.marginBalance), color: .blue),
                            (label: "Locked", value: formatCurrency(pt.marginLocked), color: .orange),
                            (label: "Leverage", value: String(format: "%.2fx", pt.leverage), color: .green),
                        ])
                        .position(x: xPos > geo.size.width / 2 ? xPos - 70 : xPos + 70, y: 40)
                    }
                }
        }
    }

    var body: some View {
        EMChartCard(title: "Capital & Leverage") {
            LegendDot(color: .blue, label: "Cash")
            LegendDot(color: .orange, label: "Margin Locked")
            LegendDot(color: .green, label: "Leverage")
        } chart: {
            if !points.isEmpty {
                ZStack { primaryChart; leverageChart }
                    .frame(height: Layout.chartFrameHeight)
                    .overlay { hoverOverlay() }
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
    }
}

// MARK: - Captured Profit Chart (Derivatives)

struct DerivativesCapturedProfitChart: View {
    let points: [DerivativesChartPoint]
    @State private var hoverIndex: Int?

    var body: some View {
        EMChartCard(title: "Captured Profit") {
            LegendDot(color: .green, label: "Realized")
            LegendDot(color: .blue, label: "Funding")
            LegendDot(color: .purple, label: "Interest")
            LegendDot(color: .cyan, label: "Rebates")
            LegendDot(color: .red, label: "Fees")
        } chart: {
            if !points.isEmpty {
                let hasNeg = points.contains { $0.sumFunding < 0 || $0.sumFees > 0 }
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        LineMark(x: .value("Date", d), y: .value("Realized", pt.sumRealized))
                            .foregroundStyle(by: .value("Series", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Funding", pt.sumFunding))
                            .foregroundStyle(by: .value("Series", "Funding"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Interest", pt.sumInterest))
                            .foregroundStyle(by: .value("Series", "Interest"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Rebates", pt.sumRebates))
                            .foregroundStyle(by: .value("Series", "Rebates"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Fees", -pt.sumFees))
                            .foregroundStyle(by: .value("Series", "Fees"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNeg { emZeroLine() }
                }
                .chartForegroundStyleScale([
                    "Realized": Color.green, "Funding": Color.blue,
                    "Interest": Color.purple, "Rebates": Color.cyan, "Fees": Color.red
                ])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy, entries: points, hoverIndex: $hoverIndex) { pt in
                        [
                            (label: "Realized", value: formatCurrency(pt.sumRealized), color: .green),
                            (label: "Funding", value: formatCurrency(pt.sumFunding), color: .blue),
                            (label: "Interest", value: formatCurrency(pt.sumInterest), color: .purple),
                            (label: "Rebates", value: formatCurrency(pt.sumRebates), color: .cyan),
                            (label: "Fees", value: formatCurrency(-pt.sumFees), color: .red),
                        ]
                    }
                }
                .frame(height: Layout.chartFrameHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)
            }
        }
    }
}
