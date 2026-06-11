import SwiftUI
import Charts

extension BacktestResult.BacktestEntry: DateIdentifiable {}

// MARK: - BacktestAPYEntry

private struct BacktestAPYEntry: DateIdentifiable {
    var id: String { date }
    let date: String
    let liquidAPY: Double
    let unrealizedAPY: Double
    let realizedAPY: Double
}

// MARK: - Charts Grid

struct BacktestChartsGrid: View {
    let result: BacktestResult
    let initialCash: Double
    @Binding var hoverVA: Int?
    @Binding var hoverCP: Int?
    @Binding var hoverGB: Int?
    @Binding var hoverAPY: Int?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        computeIsWide(sizeClass: sizeClass)
        #endif
    }

    var body: some View {
        let sampled = sampleArray(result.entries, maxPoints: 120)

        #if os(macOS)
        HStack(spacing: 8) {
            valueAllocationChart(sampled)
                .accessibilityIdentifier("chart-value-allocation")
            capturedProfitChart(sampled)
                .accessibilityIdentifier("chart-captured-profit")
        }
        .frame(height: 160)

        HStack(spacing: 8) {
            gainBreakdownChart(sampled)
                .accessibilityIdentifier("chart-gain-breakdown")
            apyBreakdownChart(sampled)
                .accessibilityIdentifier("chart-apy-breakdown")
        }
        .frame(height: 160)
        #else
        if isWide {
            // iPad: 2x2 grid
            HStack(spacing: 8) {
                valueAllocationChart(sampled)
                    .accessibilityIdentifier("chart-value-allocation")
                capturedProfitChart(sampled)
                    .accessibilityIdentifier("chart-captured-profit")
            }
            .frame(height: 180)
            HStack(spacing: 8) {
                gainBreakdownChart(sampled)
                    .accessibilityIdentifier("chart-gain-breakdown")
                apyBreakdownChart(sampled)
                    .accessibilityIdentifier("chart-apy-breakdown")
            }
            .frame(height: 180)
        } else {
            valueAllocationChart(sampled)
                .accessibilityIdentifier("chart-value-allocation")
                .frame(height: 200)
            capturedProfitChart(sampled)
                .accessibilityIdentifier("chart-captured-profit")
                .frame(height: 200)
            gainBreakdownChart(sampled)
                .accessibilityIdentifier("chart-gain-breakdown")
                .frame(height: 200)
            apyBreakdownChart(sampled)
                .accessibilityIdentifier("chart-apy-breakdown")
                .frame(height: 200)
        }
        #endif
    }

    // MARK: - Value & Allocation Chart

    @ViewBuilder
    private func valueAllocationChart(_ entries: [BacktestResult.BacktestEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Value & Allocation")
                    .font(.caption).fontWeight(.medium).foregroundColor(.textSecondary)
                Spacer()
                HStack(spacing: 8) {
                    LegendDot(color: .orange, label: "Value \(formatCurrencyCompact(entries.last?.equity ?? 0))")
                    LegendDot(color: .purple, label: "Invested \(formatCurrencyCompact(entries.last?.invested ?? 0))")
                    LegendDot(color: .green, label: "Cash \(formatCurrencyCompact(entries.last?.cash ?? 0))")
                    LegendDot(color: .cyan, label: "Target \(formatCurrencyCompact(entries.last?.expectedTarget ?? 0))")
                }
            }

            Chart {
                ForEach(entries) { entry in
                    AreaMark(x: .value("Date", entry.dateValue), y: .value("Amount", entry.invested), stacking: .standard)
                        .foregroundStyle(by: .value("Fill", "Invested"))
                        .interpolationMethod(.linear)
                    AreaMark(x: .value("Date", entry.dateValue), y: .value("Amount", entry.cash), stacking: .standard)
                        .foregroundStyle(by: .value("Fill", "Cash"))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Date", entry.dateValue), y: .value("Value", entry.equity), series: .value("Series", "Value"))
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", entry.dateValue), y: .value("Target", entry.expectedTarget), series: .value("Series", "Target"))
                        .foregroundStyle(Color.cyan)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(dash: [4, 3]))
                }
            }
            .chartForegroundStyleScale(["Invested": Color.purple, "Cash": Color.green.opacity(0.6)])
            .chartXAxis { emDateAxisTemporal() }
            .chartYAxis { emCurrencyAxis() }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy, entries: entries, hoverIndex: $hoverVA) { entry in
                    [
                        (label: "Value", value: formatCurrency(entry.equity), color: Color.orange),
                        (label: "Invested", value: formatCurrency(entry.invested), color: Color.purple),
                        (label: "Cash", value: formatCurrency(entry.cash), color: Color.green),
                        (label: "Target", value: formatCurrency(entry.expectedTarget), color: Color.cyan),
                    ]
                }
            }
        }
        .chartCard()
    }

    // MARK: - Captured Profit Chart

    @ViewBuilder
    private func capturedProfitChart(_ entries: [BacktestResult.BacktestEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Captured Profit")
                    .font(.caption).fontWeight(.medium).foregroundColor(.textSecondary)
                Spacer()
                HStack(spacing: 8) {
                    LegendDot(color: .blue, label: "Extracted \(formatCurrencyCompact(entries.last?.totalExtracted ?? 0))")
                    LegendDot(color: .cyan, label: "Interest \(formatCurrencyCompact(entries.last?.sumCashInterest ?? 0))")
                    LegendDot(color: .mint, label: "Dividends \(formatCurrencyCompact(entries.last?.sumDividends ?? 0))")
                }
            }

            Chart(entries) { entry in
                AreaMark(x: .value("Date", entry.dateValue), y: .value("Extracted", entry.totalExtracted))
                    .foregroundStyle(Color.blue.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Extracted", entry.totalExtracted))
                    .foregroundStyle(Color.blue)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Interest", entry.sumCashInterest))
                    .foregroundStyle(Color.cyan)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Dividends", entry.sumDividends))
                    .foregroundStyle(Color.mint)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis { emDateAxisTemporal() }
            .chartYAxis { emCurrencyAxis() }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy, entries: entries, hoverIndex: $hoverCP) { entry in
                    [
                        (label: "Extracted", value: formatCurrency(entry.totalExtracted), color: Color.blue),
                        (label: "Interest", value: formatCurrency(entry.sumCashInterest), color: Color.cyan),
                        (label: "Dividends", value: formatCurrency(entry.sumDividends), color: Color.mint),
                    ]
                }
            }
        }
        .chartCard()
    }

    // MARK: - Gain Breakdown Chart

    @ViewBuilder
    private func gainBreakdownChart(_ entries: [BacktestResult.BacktestEntry]) -> some View {
        let hasNegative = entries.contains { $0.liquidPnL < 0 || $0.unrealized < 0 || $0.realized < 0 }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Gain Breakdown")
                    .font(.caption).fontWeight(.medium).foregroundColor(.textSecondary)
                Spacer()
                HStack(spacing: 8) {
                    LegendDot(color: .purple, label: "Liquid")
                    LegendDot(color: .orange, label: "Unrealized")
                    LegendDot(color: .mint, label: "Realized")
                }
            }

            Chart {
                ForEach(entries) { e in
                    LineMark(x: .value("Date", e.dateValue), y: .value("Gain", e.liquidPnL))
                        .foregroundStyle(by: .value("Series", "Liquid"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", e.dateValue), y: .value("Gain", e.unrealized))
                        .foregroundStyle(by: .value("Series", "Unrealized"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", e.dateValue), y: .value("Gain", e.realized))
                        .foregroundStyle(by: .value("Series", "Realized"))
                        .interpolationMethod(.monotone)
                }
                if hasNegative { emZeroLine() }
            }
            .chartForegroundStyleScale(["Liquid": Color.purple, "Unrealized": Color.orange, "Realized": Color.mint])
            .chartXAxis { emDateAxisTemporal() }
            .chartYAxis { emCurrencyAxis() }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy, entries: entries, hoverIndex: $hoverGB) { entry in
                    [
                        (label: "Liquid", value: formatCurrency(entry.liquidPnL), color: Color.purple),
                        (label: "Unrealized", value: formatCurrency(entry.unrealized), color: Color.orange),
                        (label: "Realized", value: formatCurrency(entry.realized), color: Color.mint),
                    ]
                }
            }
        }
        .chartCard()
    }

    // MARK: - APY Breakdown Chart

    @ViewBuilder
    private func apyBreakdownChart(_ entries: [BacktestResult.BacktestEntry]) -> some View {
        let firstDate = entries.first?.date ?? ""

        let apyEntries: [BacktestAPYEntry] = entries.map { e in
            let daysElapsed = daysBetween(firstDate, e.date)
            let yearsElapsed = Double(daysElapsed) / FundMath.daysPerYear

            let unrealized = e.equity - max(0, e.invested)
            let soldCostBasis = e.totalInvested - e.invested
            let realized = (e.totalExtracted - soldCostBasis) + e.sumCashInterest + e.sumDividends
            let liquid = e.fundSize - initialCash

            let lAPY = yearsElapsed > 0 && initialCash > 0 ? liquid / initialCash / yearsElapsed : 0
            let rAPY = yearsElapsed > 0 && initialCash > 0 ? realized / initialCash / yearsElapsed : 0
            let uAPY = yearsElapsed > 0 && initialCash > 0 ? unrealized / initialCash / yearsElapsed : 0

            return BacktestAPYEntry(date: e.date, liquidAPY: lAPY, unrealizedAPY: uAPY, realizedAPY: rAPY)
        }

        let hasNegative = apyEntries.contains { $0.liquidAPY < 0 || $0.unrealizedAPY < 0 || $0.realizedAPY < 0 }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("APY Breakdown")
                    .font(.caption).fontWeight(.medium).foregroundColor(.textSecondary)
                Spacer()
                HStack(spacing: 8) {
                    LegendDot(color: .purple, label: "Liquid")
                    LegendDot(color: .orange, label: "Unrealized")
                    LegendDot(color: .mint, label: "Realized")
                }
            }

            Chart {
                ForEach(apyEntries) { e in
                    LineMark(x: .value("Date", e.dateValue), y: .value("APY", e.liquidAPY))
                        .foregroundStyle(by: .value("Series", "Liquid"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", e.dateValue), y: .value("APY", e.unrealizedAPY))
                        .foregroundStyle(by: .value("Series", "Unrealized"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", e.dateValue), y: .value("APY", e.realizedAPY))
                        .foregroundStyle(by: .value("Series", "Realized"))
                        .interpolationMethod(.monotone)
                }
                if hasNegative { emZeroLine() }
            }
            .chartForegroundStyleScale(["Liquid": Color.purple, "Unrealized": Color.orange, "Realized": Color.mint])
            .chartXAxis { emDateAxisTemporal() }
            .chartYAxis { emPercentAxis() }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy, entries: apyEntries, hoverIndex: $hoverAPY) { entry in
                    [
                        (label: "Liquid", value: formatPercent(entry.liquidAPY), color: Color.purple),
                        (label: "Unrealized", value: formatPercent(entry.unrealizedAPY), color: Color.orange),
                        (label: "Realized", value: formatPercent(entry.realizedAPY), color: Color.mint),
                    ]
                }
            }
        }
        .chartCard()
    }
}

// MARK: - Charts Placeholder

struct BacktestChartsPlaceholder: View {
    var body: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            chartPlaceholderCard("Value & Allocation")
            chartPlaceholderCard("Captured Profit")
        }
        .frame(height: 160)

        HStack(spacing: 8) {
            chartPlaceholderCard("Gain Breakdown")
            chartPlaceholderCard("APY Breakdown")
        }
        .frame(height: 160)
        #else
        chartPlaceholderCard("Value & Allocation").frame(height: 200)
        chartPlaceholderCard("Captured Profit").frame(height: 200)
        chartPlaceholderCard("Gain Breakdown").frame(height: 200)
        chartPlaceholderCard("APY Breakdown").frame(height: 200)
        #endif
    }

    private func chartPlaceholderCard(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption).fontWeight(.medium).foregroundColor(.textSecondary)
            Spacer()
            HStack {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            }
            Spacer()
        }
        .chartCard()
    }
}

// MARK: - Chart Card Modifier

private struct ChartCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(Color.bgCard)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.textMuted.opacity(0.2), lineWidth: 1)
            )
    }
}

fileprivate extension View {
    func chartCard() -> some View {
        modifier(ChartCardModifier())
    }
}

