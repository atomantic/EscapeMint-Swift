import SwiftUI
import Charts

struct BacktestView: View {
    @State private var config = BacktestConfig()
    @State private var result: BacktestResult?
    @State private var historicalData: [String: HistoricalData] = [:]
    @State private var selectedPreset: BacktestPreset = .blend
    @State private var isRunning = false
    @State private var showIntro = false

    // First-run detection
    @AppStorage("escapemint-intro-completed") private var introCompleted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if !introCompleted {
                    introCard
                }
                presetRow
                configSection
                runButton
                if let result {
                    resultCards(result)
                    resultChart(result)
                }
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        .task {
            historicalData = loadHistoricalData()
            if introCompleted {
                runBacktestAsync()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Backtest")
                    .font(.largeTitle).fontWeight(.bold).foregroundColor(.textPrimary)
                Text("Test DCA strategies against historical data")
                    .font(.subheadline).foregroundColor(.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Intro Card (First Run)

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
                    introCompleted = true
                    runBacktestAsync()
                } label: {
                    Label("Get Started", systemImage: "arrow.right.circle.fill")
                        .font(.callout).fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent).tint(.mint)

                Button {
                    introCompleted = true
                } label: {
                    Text("Skip Intro")
                        .font(.callout)
                }
                .buttonStyle(.bordered).tint(.textSecondary)
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

    // MARK: - Preset Row

    @ViewBuilder
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.headline).foregroundColor(.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BacktestPreset.allCases) { preset in
                        Button {
                            selectedPreset = preset
                            config = preset.config
                            runBacktestAsync()
                        } label: {
                            Text(preset.rawValue)
                                .font(.caption).fontWeight(.medium)
                                .foregroundColor(selectedPreset == preset ? .white : .textPrimary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(selectedPreset == preset ? Color.mint : Color.bgCard)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Config Section

    @ViewBuilder
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline).foregroundColor(.textPrimary)

            // Allocation sliders
            allocationSection

            // Investment params
            HStack(spacing: 12) {
                configField("Initial Cash", value: $config.initialCash, format: "$%.0f")
                configField("Weekly DCA", value: $config.weeklyDCA, format: "$%.0f")
                configField("Target APY", value: $config.targetAPY, format: "%.0f%%", scale: 100)
                configField("Min Profit", value: $config.minProfitUSD, format: "$%.0f")
            }

            // Mode toggle
            HStack {
                Text("Mode:")
                    .font(.caption).foregroundColor(.textSecondary)
                Picker("Mode", selection: $config.accumulate) {
                    Text("Accumulate").tag(true)
                    Text("Harvest").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    @ViewBuilder
    private var allocationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Asset Allocation")
                    .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)
                Spacer()
                let total = config.totalAllocation
                Text("\(Int(total * 100))%")
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(abs(total - 1.0) < 0.01 ? .mint : .red)
            }

            allocationSlider("SPXL", value: $config.spxlPct, color: .blue)
            allocationSlider("VTI", value: $config.vtiPct, color: .green)
            allocationSlider("BRGNX", value: $config.brgnxPct, color: .cyan)
            allocationSlider("TQQQ", value: $config.tqqqPct, color: .purple)
            allocationSlider("BTC", value: $config.btcPct, color: .orange)
            allocationSlider("GLD", value: $config.gldPct, color: .yellow)
            allocationSlider("SLV", value: $config.slvPct, color: .gray)
        }
    }

    private func allocationSlider(_ label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption).foregroundColor(.textSecondary)
                .frame(width: 50, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
                .tint(color)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption).foregroundColor(.textMuted)
                .frame(width: 35, alignment: .trailing)
        }
    }

    private func configField(_ label: String, value: Binding<Double>, format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(String(format: format, value.wrappedValue * scale))
                .font(.callout).fontWeight(.semibold).foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Run Button

    @ViewBuilder
    private var runButton: some View {
        Button {
            runBacktestAsync()
        } label: {
            HStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text("Run Backtest")
            }
            .font(.callout).fontWeight(.medium)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(.mint)
        .disabled(isRunning || abs(config.totalAllocation - 1.0) > 0.01)
    }

    // MARK: - Results

    @ViewBuilder
    private func resultCards(_ result: BacktestResult) -> some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 10), count: 5), spacing: 10) {
            MetricCard(label: "Final Value", value: formatCurrency(result.finalValue), color: .mint)
            MetricCard(label: "Total Invested", value: formatCurrency(result.totalInvested))
            MetricCard(label: "Total Gain", value: formatCurrency(result.totalGain),
                       color: result.totalGain >= 0 ? .mint : .red)
            MetricCard(label: "Return", value: formatPercent(result.gainPct),
                       color: result.gainPct >= 0 ? .mint : .red)
            MetricCard(label: "APY", value: formatPercent(result.apy),
                       sub: "\(result.weeks) weeks",
                       color: result.apy >= 0 ? .mint : .red)
            MetricCard(label: "Max Drawdown", value: formatPercent(result.maxDrawdown), color: .red)
        }
    }

    @ViewBuilder
    private func resultChart(_ result: BacktestResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Portfolio Value Over Time")
                .font(.headline).foregroundColor(.textPrimary)

            let sampled = sampleBacktestEntries(result.entries, maxPoints: 80)
            Chart(sampled.indices, id: \.self) { i in
                let entry = sampled[i]
                AreaMark(x: .value("Date", entry.date), y: .value("Value", entry.totalValue))
                    .foregroundStyle(Color.mint.opacity(0.15))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.date), y: .value("Value", entry.totalValue))
                    .foregroundStyle(Color.mint)
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", entry.date), y: .value("Invested", entry.costBasis))
                    .foregroundStyle(Color.textMuted)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(dash: [4, 4]))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
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
            .frame(height: 250)

            HStack(spacing: 16) {
                LegendDot(color: .mint, label: "Total Value")
                LegendDot(color: .textMuted, label: "Cost Basis (invested)")
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func runBacktestAsync() {
        isRunning = true
        let cfg = config
        let hist = historicalData
        Task.detached {
            let r = runBacktest(config: cfg, historicalData: hist)
            await MainActor.run {
                result = r
                isRunning = false
            }
        }
    }
}

private func sampleBacktestEntries(_ entries: [BacktestResult.BacktestEntry], maxPoints: Int) -> [BacktestResult.BacktestEntry] {
    let step = max(1, entries.count / maxPoints)
    return entries.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == entries.count - 1 }
        .map(\.element)
}
