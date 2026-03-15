import SwiftUI
import Charts

// MARK: - Derivatives Chart Data

struct DerivativesChartPoint: Identifiable {
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

// MARK: - Current State Card (Closed Funds)

struct ClosedFundStateCard: View {
    let closedMetrics: ClosedFundMetrics

    var body: some View {
        let cm = closedMetrics
        VStack(alignment: .leading, spacing: 6) {
            Text("Current State")
                .font(.headline).foregroundColor(.textPrimary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    metricLabel("Total Invested", formatCurrency(cm.totalInvestedUsd))
                    metricLabel("Total Returned", formatCurrency(cm.totalReturnedUsd))
                }
                GridRow {
                    metricLabel("Net Gain/Loss", "\(formatCurrency(cm.netGainUsd)) (\(formatPercent(cm.returnPct)))", color: cm.netGainUsd >= 0 ? .mint : .red)
                    metricLabel("Annualized Return", formatPercent(cm.apy), color: cm.apy > 0 ? .mint : .red)
                }
                GridRow {
                    metricLabel("Dividends", formatCurrency(cm.totalDividendsUsd))
                    metricLabel("Cash Interest", formatCurrency(cm.totalCashInterestUsd))
                }
                GridRow {
                    metricLabel("Duration", "\(cm.durationDays) days")
                    metricLabel("Expenses", formatCurrency(-cm.totalExpensesUsd), color: cm.totalExpensesUsd > 0 ? .red : .white)
                }
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func metricLabel(_ label: String, _ value: String, color: Color = .textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.semibold).foregroundColor(color)
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
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
    }
}

// MARK: - APY Chart (Derivatives)

struct DerivativesAPYChart: View {
    let points: [DerivativesChartPoint]
    var fundId: String = ""
    var bounds: ChartBounds?

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
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
    }
}

// MARK: - Value & Allocation Chart

struct DerivativesValueChart: View {
    let points: [DerivativesChartPoint]

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
                            .interpolationMethod(.linear)
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
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
    }
}

// MARK: - Price & Liquidation Chart

struct DerivativesPriceChart: View {
    let points: [DerivativesChartPoint]
    var fundId: String = ""
    var bounds: ChartBounds?

    var body: some View {
        let withPosition = points.filter { $0.position > 0 && $0.avgEntry > 0 }
        EMChartCard(title: "Price & Liquidation") {
            LegendDot(color: .orange, label: "Avg Entry")
            LegendDot(color: .mint, label: "Liq Price")
            if !fundId.isEmpty { ChartBoundsButton(fundId: fundId, boundsKey: "derivativesPrice", isPercent: false, bounds: bounds) }
        } chart: {
            if withPosition.count >= 2 {
                let hasNeg = withPosition.contains { $0.liqPrice < 0 }
                Chart {
                    ForEach(withPosition) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        LineMark(x: .value("Date", d), y: .value("Avg Entry", pt.avgEntry))
                            .foregroundStyle(by: .value("Series", "Avg Entry"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Liq Price", pt.liqPrice))
                            .foregroundStyle(by: .value("Series", "Liq Price"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                    }
                    if hasNeg { emZeroLine() }
                }
                .chartForegroundStyleScale(["Avg Entry": Color.orange, "Liq Price": Color.mint])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartYScale(domain: chartYDomain(bounds, points: withPosition.flatMap { [$0.avgEntry, $0.liqPrice] }))
                .chartLegend(.hidden)
                .frame(height: 160)
            } else {
                Text("Not enough position data")
                    .font(.caption).foregroundColor(.textMuted)
                    .frame(height: 160)
            }
        }
    }
}

// MARK: - Capital & Leverage Chart

struct DerivativesMarginChart: View {
    let points: [DerivativesChartPoint]

    var body: some View {
        EMChartCard(title: "Capital & Leverage") {
            LegendDot(color: .blue, label: "Cash")
            LegendDot(color: .orange, label: "Margin Locked")
        } chart: {
            if !points.isEmpty {
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
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
    }
}

// MARK: - Captured Profit Chart (Derivatives)

struct DerivativesCapturedProfitChart: View {
    let points: [DerivativesChartPoint]

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
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
    }
}
