import SwiftUI
import Charts

struct BacktestView: View {
    private var cache: ViewCache { .shared }
    @State private var config: BacktestConfig
    @State private var selectedPreset: BacktestPreset
    @State private var showIntroGuide = false
    @State private var dateRange: BacktestDateRange?
    @State private var sortOrder: SortOrder
    @State private var hoverVA: Int?
    @State private var hoverCP: Int?
    @State private var hoverGB: Int?
    @State private var hoverAPY: Int?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    // First-run detection
    @AppStorage("escapemint-intro-completed") private var introCompleted = false

    // Read expensive results from persistent cache
    private var result: BacktestResult? { cache.backtestResult }
    private var historicalData: [String: HistoricalData] { cache.historicalData }
    private var isRunning: Bool { cache.isRunningBacktest }
    private var availableRange: BacktestDateRange? { cache.backtestAvailableRange }

    enum SortOrder {
        case asc, desc
    }

    init() {
        let c = ViewCache.shared
        _config = State(initialValue: c.backtestConfig)
        _selectedPreset = State(initialValue: c.backtestPreset)
        _dateRange = State(initialValue: c.backtestDateRange)
        _sortOrder = State(initialValue: c.backtestSortOrder == .asc ? .asc : .desc)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                if !introCompleted {
                    introCard
                }
                BacktestConfigPanel(
                    config: $config,
                    selectedPreset: $selectedPreset,
                    onConfigChanged: runBacktestAsync
                )
                metricsGrid
                chartsGrid
                entriesTable
            }
            .padding()
        }
        .clipped()
        .background(Color.bg.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Backtest")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            cache.updateBacktestConfig(config)
            if cache.isHistoricalDataLoaded {
                initAndRun()
            }
        }
        .onChange(of: cache.isHistoricalDataLoaded) { _, loaded in
            if loaded { initAndRun() }
        }
        .sheet(isPresented: $showIntroGuide) {
            IntroGuideView(isPresented: $showIntroGuide)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        #if os(macOS)
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
        #else
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bet long on the future to build a money tree")
                    .font(.caption).foregroundColor(.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    showIntroGuide = true
                } label: {
                    Label("Guide", systemImage: "book.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered).tint(.mint)
                .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                dateRangePicker
            }
        }
        #endif
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
                                .font(.caption2.weight(.medium))
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
                introStep(3, "Run the backtest to see simulated historical returns")
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

    // MARK: - Metrics Grid (8 cards)

    @ViewBuilder
    private var metricsGrid: some View {
        if let result {
            #if os(macOS)
            let columnCount = 8
            #else
            let columnCount = isWide ? 4 : 2
            #endif
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
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
                           color: .mint)
            }
        } else if isRunning {
            metricsPlaceholder
        }
    }

    @ViewBuilder
    private var metricsPlaceholder: some View {
        #if os(macOS)
        let columnCount = 8
        #else
        let columnCount = isWide ? 4 : 2
        #endif
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(["Final Value", "Liquid APY", "Realized APY", "Unrealized Gain",
                     "Realized Gain", "Liquid P&L", "Total Invested", "Total Extracted"], id: \.self) { label in
                MetricCard(label: label, value: "---", sub: "loading...", color: .textMuted)
                    .redacted(reason: .placeholder)
                    .shimmer()
            }
        }
    }

    // MARK: - Charts Grid

    @ViewBuilder
    private var chartsGrid: some View {
        if let result, result.entries.count > 1 {
            BacktestChartsGrid(
                result: result,
                initialCash: config.initialCash,
                hoverVA: $hoverVA,
                hoverCP: $hoverCP,
                hoverGB: $hoverGB,
                hoverAPY: $hoverAPY
            )
        } else if isRunning {
            BacktestChartsPlaceholder()
        }
    }

    // MARK: - Entries Table

    @ViewBuilder
    private var entriesTable: some View {
        if result == nil, isRunning {
            BacktestTablePlaceholder()
        } else if let result, !result.entries.isEmpty {
            BacktestTransactions(result: result, sortOrder: $sortOrder)
        }
    }

    // MARK: - Actions

    private func initAndRun() {
        cache.updateAvailableRange()
        if dateRange == nil {
            dateRange = cache.backtestAvailableRange
        }
        if introCompleted {
            runBacktestAsync()
        }
    }

    private func runBacktestAsync() {
        cache.updateBacktestConfig(config)
        cache.updateBacktestDateRange(dateRange)
        cache.updateBacktestPreset(selectedPreset)
        cache.updateBacktestSortOrder(sortOrder == .asc ? .asc : .desc)
        cache.runBacktestIfNeeded()
    }
}

// MARK: - Asset Colors

extension Color {
    static let assetSPXL = Color(
        light: Color(red: 59/255, green: 130/255, blue: 246/255),    // blue
        dark: Color(red: 96/255, green: 165/255, blue: 250/255)      // blue-400
    )
    static let assetVTI = Color(
        light: Color(red: 139/255, green: 92/255, blue: 246/255),    // purple
        dark: Color(red: 167/255, green: 139/255, blue: 250/255)     // purple-400
    )
    static let assetBRGNX = Color(
        light: Color(red: 6/255, green: 182/255, blue: 212/255),     // cyan
        dark: Color(red: 34/255, green: 211/255, blue: 238/255)      // cyan-400
    )
    static let assetTQQQ = Color(
        light: Color(red: 34/255, green: 197/255, blue: 94/255),     // green
        dark: Color(red: 74/255, green: 222/255, blue: 128/255)      // green-400
    )
    static let assetBTC = Color(
        light: Color(red: 249/255, green: 115/255, blue: 22/255),    // orange
        dark: Color(red: 251/255, green: 146/255, blue: 60/255)      // orange-400
    )
    static let assetGLD = Color(
        light: Color(red: 234/255, green: 179/255, blue: 8/255),     // yellow
        dark: Color(red: 250/255, green: 204/255, blue: 21/255)      // yellow-400
    )
    static let assetSLV = Color(
        light: Color(red: 148/255, green: 163/255, blue: 184/255),   // gray
        dark: Color(red: 203/255, green: 213/255, blue: 225/255)     // slate-300
    )
}
