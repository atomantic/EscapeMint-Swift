import SwiftUI
import Charts

struct BacktestView: View {
    @State private var config = BacktestConfig()
    @State private var result: BacktestResult?
    @State private var historicalData: [String: HistoricalData] = [:]
    @State private var selectedPreset: BacktestPreset = .blend
    @State private var isRunning = false
    @State private var showIntroGuide = false
    @State private var dateRange: BacktestDateRange?
    @State private var availableRange: BacktestDateRange?
    @State private var sortOrder: BacktestSortOrder = .asc
    @State private var backtestTask: Task<Void, Never>?
    @State private var hoverVA: Int?
    @State private var hoverCP: Int?
    @State private var hoverGB: Int?
    @State private var hoverAPY: Int?

    // First-run detection
    @AppStorage("escapemint-intro-completed") private var introCompleted = false

    enum BacktestSortOrder {
        case asc, desc
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if !introCompleted {
                    introCard
                }
                configPanel
                metricsGrid
                chartsGrid
                entriesTable
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        .task {
            historicalData = loadHistoricalData()
            updateAvailableRange()
            if introCompleted {
                runBacktestAsync()
            }
        }
        .sheet(isPresented: $showIntroGuide) {
            IntroGuideView(isPresented: $showIntroGuide)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Backtest")
                    .font(.largeTitle).fontWeight(.bold).foregroundColor(.textPrimary)
                Text("Bet long on the future to build a money tree")
                    .font(.subheadline).foregroundColor(.textSecondary)
            }
            Spacer()
            dateRangePicker
            Button {
                showIntroGuide = true
            } label: {
                Label("Guide", systemImage: "book.fill")
                    .font(.callout)
            }
            .buttonStyle(.bordered).tint(.mint)
        }
    }

    // MARK: - Date Range Picker

    @ViewBuilder
    private var dateRangePicker: some View {
        if let avail = availableRange {
            HStack(spacing: 8) {
                let startBinding = Binding<String>(
                    get: { dateRange?.start ?? avail.start },
                    set: { newVal in
                        dateRange = BacktestDateRange(start: newVal, end: dateRange?.end ?? avail.end)
                        runBacktestAsync()
                    }
                )
                let endBinding = Binding<String>(
                    get: { dateRange?.end ?? avail.end },
                    set: { newVal in
                        dateRange = BacktestDateRange(start: dateRange?.start ?? avail.start, end: newVal)
                        runBacktestAsync()
                    }
                )

                dateInput(value: startBinding)
                Text("to").font(.caption).foregroundColor(.textMuted)
                dateInput(value: endBinding)

                if let dr = dateRange ?? availableRange {
                    Text("\(dr.daysElapsed)d (\(String(format: "%.1f", dr.yearsElapsed))y)")
                        .font(.caption2).foregroundColor(.textMuted)
                }

                HStack(spacing: 2) {
                    ForEach(["YTD", "1Y", "2Y", "3Y", "4Y", "ALL"], id: \.self) { preset in
                        Button {
                            applyDatePreset(preset, available: avail)
                        } label: {
                            Text(preset)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Color.bgInput)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func dateInput(value: Binding<String>) -> some View {
        TextField("", text: value)
            .font(.caption).foregroundColor(.textPrimary)
            .frame(width: 85)
            .textFieldStyle(.roundedBorder)
    }

    private func applyDatePreset(_ preset: String, available: BacktestDateRange) {
        let end = available.end
        let cal = Calendar.current
        let df = isoDateFormatter

        guard let endDate = df.date(from: end) else { return }

        var startDate: Date?
        switch preset {
        case "YTD":
            startDate = cal.date(from: cal.dateComponents([.year], from: endDate))
        case "1Y":
            startDate = cal.date(byAdding: .year, value: -1, to: endDate)
        case "2Y":
            startDate = cal.date(byAdding: .year, value: -2, to: endDate)
        case "3Y":
            startDate = cal.date(byAdding: .year, value: -3, to: endDate)
        case "4Y":
            startDate = cal.date(byAdding: .year, value: -4, to: endDate)
        case "ALL":
            dateRange = available
            runBacktestAsync()
            return
        default:
            return
        }

        guard let sd = startDate else { return }
        let startStr = max(df.string(from: sd), available.start)
        dateRange = BacktestDateRange(start: startStr, end: end)
        runBacktestAsync()
    }

    // MARK: - Intro Card

    @ViewBuilder
    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2).foregroundColor(.mint)
                Text("Welcome to EscapeMint")
                    .font(.title2).fontWeight(.bold).foregroundColor(.textPrimary)
            }

            Text("EscapeMint helps you build a Dollar Cost Averaging (DCA) strategy for long-term wealth building. Before you start tracking real funds, try backtesting a strategy against historical data to see how it would have performed.")
                .font(.subheadline).foregroundColor(.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                introStep(1, "Choose a preset or customize your asset allocation below")
                introStep(2, "Set your initial cash, weekly DCA amount, and target APY")
                introStep(3, "Run the backtest to see projected returns")
                introStep(4, "When ready, go to Dashboard and create your first real fund")
            }

            HStack {
                Button {
                    showIntroGuide = true
                } label: {
                    Label("Read Full Guide", systemImage: "book.fill")
                        .font(.callout).fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent).tint(.mint)
                .accessibilityIdentifier("btn-read-guide")

                Button {
                    introCompleted = true
                    runBacktestAsync()
                } label: {
                    Label("Get Started", systemImage: "arrow.right.circle.fill")
                        .font(.callout).fontWeight(.medium)
                }
                .buttonStyle(.bordered).tint(.mint)
                .accessibilityIdentifier("btn-get-started")
                .accessibilityLabel("Get Started")

                Button {
                    introCompleted = true
                } label: {
                    Text("Skip").font(.callout)
                }
                .buttonStyle(.bordered).tint(.textSecondary)
                .accessibilityIdentifier("btn-skip-intro")
                .accessibilityLabel("Skip")
            }
        }
        .padding(16)
        .background(Color.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mint.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func introStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold).foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.mint).cornerRadius(10)
            Text(text)
                .font(.caption).foregroundColor(.textSecondary)
        }
    }

    // MARK: - Config Panel (4-column layout)

    @ViewBuilder
    private var configPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Column 1: Allocation
                allocationColumn

                Divider().frame(height: 180)

                // Column 2: Strategy
                strategyColumn

                Divider().frame(height: 180)

                // Column 3: DCA Tiers
                dcaTiersColumn

                Divider().frame(height: 180)

                // Column 4: Fund Mode + Presets
                fundModeColumn
            }
            .padding(12)
        }
        .background(Color.bgCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.textMuted.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var allocationColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allocation").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            // Allocation bar
            allocationBar
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Asset allocation bar showing \(allocationBarSegments.map { "\($0.label) \(Int($0.pct * 100))%" }.joined(separator: ", "))")

            // Sliders
            allocationSlider("SPXL", value: $config.spxlPct, color: .assetSPXL)
            allocationSlider("VTI", value: $config.vtiPct, color: .assetVTI)
            allocationSlider("BRGNX", value: $config.brgnxPct, color: .assetBRGNX)
            allocationSlider("TQQQ", value: $config.tqqqPct, color: .assetTQQQ)
            allocationSlider("BTC", value: $config.btcPct, color: .assetBTC)
            allocationSlider("GLD", value: $config.gldPct, color: .assetGLD)
            allocationSlider("SLV", value: $config.slvPct, color: .assetSLV)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("allocation-section")
    }

    @ViewBuilder
    private var allocationBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(allocationBarSegments, id: \.label) { segment in
                    let width = geo.size.width * segment.pct
                    if width > 0 {
                        ZStack {
                            Rectangle().fill(segment.color)
                            if segment.pct >= 0.20 {
                                Text("\(segment.label) \(Int(segment.pct * 100))%")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                            } else if segment.pct >= 0.10 {
                                Text("\(Int(segment.pct * 100))%")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: width)
                    }
                }
            }
        }
        .frame(height: 20)
        .cornerRadius(4)
    }

    private var allocationBarSegments: [(label: String, pct: Double, color: Color)] {
        [
            ("SPXL", config.spxlPct, .assetSPXL),
            ("VTI", config.vtiPct, .assetVTI),
            ("BRGNX", config.brgnxPct, .assetBRGNX),
            ("TQQQ", config.tqqqPct, .assetTQQQ),
            ("BTC", config.btcPct, .assetBTC),
            ("GLD", config.gldPct, .assetGLD),
            ("SLV", config.slvPct, .assetSLV),
        ].filter { $0.pct > 0 }
    }

    private func allocationSlider(_ label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 10)).foregroundColor(.textSecondary)
                .frame(width: 42, alignment: .leading)
            CompactSlider(value: value, range: 0...1, step: 0.05, tint: color) {
                runBacktestAsync()
            }
            .accessibilityLabel("\(label) allocation")
            .accessibilityValue("\(Int(value.wrappedValue * 100)) percent")
            .accessibilityIdentifier("slider-\(label.lowercased())")
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.textMuted)
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var strategyColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strategy").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            styledSlider("Initial Cash", value: $config.initialCash,
                         range: 1000...100000, step: 1000,
                         format: { formatCurrency($0) })
            styledSlider("Target APY", value: $config.targetAPY,
                         range: 0...1, step: 0.01,
                         format: { "\(Int($0 * 100))%" })
            styledSlider("Min Profit", value: $config.minProfitUSD,
                         range: 0...5000, step: 50,
                         format: { formatCurrency($0) })
            styledSlider("Cash APY", value: $config.cashAPY,
                         range: 0...0.10, step: 0.005,
                         format: { String(format: "%.1f%%", $0 * 100) })
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var dcaTiersColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DCA Tiers").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            styledSlider("Min (\u{2265} target)", value: $config.inputMin,
                         range: 0...1000, step: 10,
                         format: { formatCurrency($0) })
            styledSlider("Mid (< target)", value: $config.inputMid,
                         range: 0...1000, step: 10,
                         format: { formatCurrency($0) })
            styledSlider("Max (\u{2264} \(Int(config.maxAtPct * 100))%)", value: $config.inputMax,
                         range: 0...1000, step: 10,
                         format: { formatCurrency($0) })

            let thresholdBinding = Binding<Double>(
                get: { abs(config.maxAtPct) * 100 },
                set: { config.maxAtPct = -($0 / 100) }
            )
            styledSlider("Threshold", value: thresholdBinding,
                         range: 10...50, step: 5,
                         format: { "-\(Int($0))%" })
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var fundModeColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fund Mode").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            // Accumulate / Harvest toggle
            HStack(spacing: 2) {
                Button {
                    config.accumulate = true
                    runBacktestAsync()
                } label: {
                    Text("Accumulate")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(config.accumulate ? Color.blue : Color.bgInput)
                        .foregroundColor(config.accumulate ? .white : .textMuted)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Accumulate mode")
                .accessibilityAddTraits(config.accumulate ? .isSelected : [])
                .accessibilityIdentifier("btn-accumulate")

                Button {
                    config.accumulate = false
                    runBacktestAsync()
                } label: {
                    Text("Harvest")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(!config.accumulate ? Color.orange : Color.bgInput)
                        .foregroundColor(!config.accumulate ? .white : .textMuted)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Harvest mode")
                .accessibilityAddTraits(!config.accumulate ? .isSelected : [])
                .accessibilityIdentifier("btn-harvest")
            }

            Text(config.accumulate
                 ? "Sell min DCA amount when over target + min profit. All proceeds stay in fund cash pool."
                 : "Close entire position to cash when over target + min profit. All proceeds stay in fund cash pool.")
                .font(.system(size: 9))
                .foregroundColor(.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            // Presets
            Text("Presets").font(.system(size: 9)).foregroundColor(.textMuted)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(BacktestPreset.allCases) { preset in
                    Button {
                        selectedPreset = preset
                        config = preset.config(accumulate: config.accumulate)
                        runBacktestAsync()
                    } label: {
                        Text(preset.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(selectedPreset == preset
                                        ? (config.accumulate ? Color.blue : Color.orange)
                                        : Color.bgInput)
                            .foregroundColor(selectedPreset == preset ? .white : .textSecondary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preset \(preset.rawValue)")
                    .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
                    .accessibilityIdentifier("preset-\(preset.rawValue.lowercased())")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fund-mode-section")
    }

    private func styledSlider(_ label: String, value: Binding<Double>,
                              range: ClosedRange<Double>, step: Double,
                              format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10)).foregroundColor(.textMuted)
                .frame(width: 85, alignment: .leading)
                .lineLimit(1)
            CompactSlider(value: value, range: range, step: step, tint: .blue) {
                runBacktestAsync()
            }
            .accessibilityLabel(label)
            .accessibilityValue(format(value.wrappedValue))
            .accessibilityIdentifier("slider-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.textSecondary)
                .frame(width: 60, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Metrics Grid (8 cards)

    @ViewBuilder
    private var metricsGrid: some View {
        if let result {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)
            LazyVGrid(columns: columns, spacing: 8) {
                MetricCard(label: "Final Value",
                           value: formatCurrency(result.finalValue),
                           sub: formatPercentSigned(result.liquidGain / max(1, config.initialCash)),
                           color: result.liquidGain >= 0 ? .mint : .red)
                MetricCard(label: "Liquid APY",
                           value: formatPercent(result.liquidAPY),
                           sub: "annualized",
                           color: result.liquidAPY >= 0 ? .mint : .red)
                MetricCard(label: "Realized APY",
                           value: formatPercent(result.realizedAPY),
                           sub: "from extractions",
                           color: result.realizedAPY >= 0 ? .mint : .red)
                MetricCard(label: "Unrealized Gain",
                           value: formatCurrency(result.unrealizedGain),
                           sub: "paper gains",
                           color: result.unrealizedGain >= 0 ? .mint : .red)
                MetricCard(label: "Realized Gain",
                           value: formatCurrency(result.realizedGain),
                           sub: "extracted profits",
                           color: result.realizedGain >= 0 ? .mint : .red)
                MetricCard(label: "Liquid P&L",
                           value: formatCurrency(result.liquidGain),
                           sub: "total gain/loss",
                           color: result.liquidGain >= 0 ? .mint : .red)
                MetricCard(label: "Total Invested",
                           value: formatCurrency(result.totalInvested),
                           sub: "\(result.totalBuys) buys",
                           color: .blue)
                MetricCard(label: "Total Extracted",
                           value: formatCurrency(result.totalExtracted),
                           sub: "\(result.totalSells) sells",
                           color: .purple)
            }
        }
    }

    // MARK: - Charts Grid (2x2)

    @ViewBuilder
    private var chartsGrid: some View {
        if let result, result.entries.count > 1 {
            let sampled = sampleArray(result.entries, maxPoints: 120)

            HStack(spacing: 12) {
                valueAllocationChart(sampled)
                    .accessibilityIdentifier("chart-value-allocation")
                capturedProfitChart(sampled)
                    .accessibilityIdentifier("chart-captured-profit")
            }
            .frame(height: 200)

            HStack(spacing: 12) {
                gainBreakdownChart(sampled)
                    .accessibilityIdentifier("chart-gain-breakdown")
                apyBreakdownChart(sampled)
                    .accessibilityIdentifier("chart-apy-breakdown")
            }
            .frame(height: 200)
        }
    }

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

            Chart(entries) { entry in
                AreaMark(x: .value("Date", entry.dateValue), y: .value("Invested", entry.invested))
                    .foregroundStyle(Color.purple.opacity(0.3))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("Date", entry.dateValue), y: .value("Cash", entry.cash))
                    .foregroundStyle(Color.green.opacity(0.2))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Value", entry.equity))
                    .foregroundStyle(Color.orange)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Target", entry.expectedTarget))
                    .foregroundStyle(Color.cyan)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(dash: [4, 3]))
            }
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
                    .foregroundStyle(Color.blue.opacity(0.3))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Extracted", entry.totalExtracted))
                    .foregroundStyle(Color.blue)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Interest", entry.sumCashInterest))
                    .foregroundStyle(Color.cyan)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.dateValue), y: .value("Dividends", entry.sumDividends))
                    .foregroundStyle(Color.mint)
                    .interpolationMethod(.catmullRom)
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
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", e.dateValue), y: .value("Gain", e.unrealized))
                        .foregroundStyle(by: .value("Series", "Unrealized"))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", e.dateValue), y: .value("Gain", e.realized))
                        .foregroundStyle(by: .value("Series", "Realized"))
                        .interpolationMethod(.catmullRom)
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

    @ViewBuilder
    private func apyBreakdownChart(_ entries: [BacktestResult.BacktestEntry]) -> some View {
        let firstDate = entries.first?.date ?? ""
        let initialCash = config.initialCash

        let apyEntries: [BacktestAPYEntry] = entries.map { e in
            let daysElapsed = daysBetween(firstDate, e.date)
            let yearsElapsed = Double(daysElapsed) / 365.0

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
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", e.dateValue), y: .value("APY", e.unrealizedAPY))
                        .foregroundStyle(by: .value("Series", "Unrealized"))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", e.dateValue), y: .value("APY", e.realizedAPY))
                        .foregroundStyle(by: .value("Series", "Realized"))
                        .interpolationMethod(.catmullRom)
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

    // MARK: - Entries Table

    @ViewBuilder
    private var entriesTable: some View {
        if let result, !result.entries.isEmpty {
            let sorted = sortOrder == .asc ? result.entries : result.entries.reversed()

            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        // Header
                        HStack(spacing: 0) {
                            tableHeaderCell("Date", width: 90, sortable: true)
                            tableHeaderCell("Fund Size", width: 85)
                            tableHeaderCell("Equity", width: 85)
                            tableHeaderCell("Cash", width: 85)
                            tableHeaderCell("Interest", width: 70)
                            tableHeaderCell("\u{03A3} Interest", width: 75)
                            tableHeaderCell("Dividend", width: 70)
                            tableHeaderCell("\u{03A3} Dividend", width: 80)
                            tableHeaderCell("Action", width: 55)
                            tableHeaderCell("Amount", width: 80)
                            tableHeaderCell("Invested", width: 80)
                            tableHeaderCell("Unrealized", width: 85)
                            tableHeaderCell("Realized", width: 85)
                            tableHeaderCell("Liquid P&L", width: 85)
                            tableHeaderCell("Target", width: 85)
                        }
                        .padding(.vertical, 6)
                        .background(Color.bgCard)

                        Divider().background(Color.textMuted.opacity(0.3))

                        // Rows
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(sorted) { entry in
                                    entryRow(entry)
                                    Divider().background(Color.textMuted.opacity(0.15))
                                }
                            }
                        }
                        .frame(maxHeight: 500)
                    }
                }

                // Footer
                HStack {
                    Text("\(result.entries.count) entries")
                        .font(.caption2).foregroundColor(.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.bg.opacity(0.5))
            }
            .background(Color.bgCard)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.textMuted.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func tableHeaderCell(_ title: String, width: CGFloat, sortable: Bool = false) -> some View {
        Group {
            if sortable {
                Button {
                    sortOrder = sortOrder == .asc ? .desc : .asc
                } label: {
                    HStack(spacing: 2) {
                        Text(title)
                        Text(sortOrder == .asc ? "\u{25B2}" : "\u{25BC}")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textMuted)
                    .frame(width: width, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textMuted)
                    .frame(width: width, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func entryRow(_ entry: BacktestResult.BacktestEntry) -> some View {
        let bgColor: Color = {
            switch entry.action {
            case .BUY: return Color.green.opacity(0.05)
            case .SELL: return Color.red.opacity(0.05)
            default: return Color.clear
            }
        }()

        HStack(spacing: 0) {
            Text(entry.date)
                .frame(width: 90, alignment: .leading)
                .foregroundColor(.textPrimary)

            Text(formatCurrency(entry.fundSize))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.textSecondary)

            Text(formatCurrency(entry.equity))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.mint)

            Text(formatCurrency(entry.cash))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.green)

            Text(entry.cashInterest > 0.01 ? formatCurrency(entry.cashInterest) : "-")
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.cyan)

            Text(formatCurrency(entry.sumCashInterest))
                .frame(width: 75, alignment: .trailing)
                .foregroundColor(.cyan.opacity(0.7))

            Text(entry.dividend > 0.01 ? formatCurrency(entry.dividend) : "-")
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.mint)

            Text(formatCurrency(entry.sumDividends))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.mint.opacity(0.7))

            Text(entry.action?.rawValue ?? "HOLD")
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(actionColor(entry.action))

            Group {
                if entry.amount > 0 {
                    Text(formatCurrency(entry.amount))
                        .foregroundColor(entry.action == .BUY ? .green : .red)
                } else {
                    Text("-").foregroundColor(.textMuted)
                }
            }
            .frame(width: 80, alignment: .trailing)

            Text(formatCurrency(max(0, entry.invested)))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.blue)

            Text(formatCurrency(entry.unrealized))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(entry.unrealized >= 0 ? .green : .red)

            Text(formatCurrency(entry.realized))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(entry.realized >= 0 ? .green : .red)

            Text(formatCurrency(entry.liquidPnL))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(entry.liquidPnL >= 0 ? .green : .red)

            Text(formatCurrency(entry.expectedTarget))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.cyan)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(bgColor)
    }

    private func actionColor(_ action: FundAction?) -> Color {
        switch action {
        case .BUY: return .green
        case .SELL: return .orange
        default: return .textMuted
        }
    }

    // MARK: - Actions

    private func updateAvailableRange() {
        availableRange = computeAvailableDateRange(
            historicalData: historicalData,
            allocations: config.allocations
        )
        if dateRange == nil {
            dateRange = availableRange
        }
    }

    private func runBacktestAsync() {
        updateAvailableRange()
        backtestTask?.cancel()
        isRunning = true
        let cfg = config
        let hist = historicalData
        let dr = dateRange
        backtestTask = Task {
            let r = runBacktest(config: cfg, historicalData: hist, dateRange: dr)
            guard !Task.isCancelled else { return }
            result = r
            isRunning = false
        }
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

private extension View {
    func chartCard() -> some View {
        modifier(ChartCardModifier())
    }
}

// MARK: - Chart Hover Overlay

private protocol DateIdentifiable: Identifiable {
    var date: String { get }
    var dateValue: Date { get }
}

extension DateIdentifiable {
    var dateValue: Date {
        isoDateFormatter.date(from: date) ?? .distantPast
    }
}

extension BacktestResult.BacktestEntry: DateIdentifiable {}

private struct BacktestAPYEntry: DateIdentifiable {
    var id: String { date }
    let date: String
    let liquidAPY: Double
    let unrealizedAPY: Double
    let realizedAPY: Double
}

private func chartHoverOverlay<T: DateIdentifiable>(
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
                        let lines = tooltipLines(entry)

                        // Vertical dashed hover line
                        Path { path in
                            path.move(to: CGPoint(x: xPos, y: frame.origin.y))
                            path.addLine(to: CGPoint(x: xPos, y: frame.origin.y + frame.height))
                        }
                        .stroke(Color.textMuted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        // Tooltip card
                        let flipLeft = xPos > frame.midX
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatTooltipDate(entry.date))
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
                        .position(
                            x: flipLeft ? xPos - 70 : xPos + 70,
                            y: frame.origin.y + 40
                        )
                    }
                }
        }
    }
}

// MARK: - Compact Slider (no macOS tick marks)

private struct CompactSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let onDragEnd: () -> Void

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, tint: Color, onDragEnd: @escaping () -> Void) {
        self._value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.onDragEnd = onDragEnd
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (value - range.lowerBound) / span : 0
            let trackH: CGFloat = 4
            let thumbD: CGFloat = 14

            ZStack(alignment: .leading) {
                // Track background
                Capsule().fill(Color.textMuted.opacity(0.15))
                    .frame(height: trackH)
                // Filled track
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * frac), height: trackH)
                // Thumb
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .frame(width: thumbD, height: thumbD)
                    .offset(x: max(0, min(geo.size.width - thumbD, geo.size.width * frac - thumbD / 2)))
            }
            .frame(height: thumbD)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onDragEnd { drag in
                        let pct = max(0, min(1, drag.location.x / geo.size.width))
                        let raw = range.lowerBound + pct * span
                        let stepped = step > 0 ? (raw / step).rounded() * step : raw
                        value = max(range.lowerBound, min(range.upperBound, stepped))
                    }
                    .onEnded { _ in onDragEnd() }
            )
        }
        .frame(height: 14)
    }
}

// MARK: - Asset Colors

extension Color {
    static let assetSPXL = Color(red: 59/255, green: 130/255, blue: 246/255)   // blue
    static let assetVTI = Color(red: 139/255, green: 92/255, blue: 246/255)    // purple
    static let assetBRGNX = Color(red: 6/255, green: 182/255, blue: 212/255)   // cyan
    static let assetTQQQ = Color(red: 34/255, green: 197/255, blue: 94/255)    // green
    static let assetBTC = Color(red: 249/255, green: 115/255, blue: 22/255)    // orange
    static let assetGLD = Color(red: 234/255, green: 179/255, blue: 8/255)     // yellow
    static let assetSLV = Color(red: 148/255, green: 163/255, blue: 184/255)   // gray
}

