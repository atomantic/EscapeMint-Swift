import SwiftUI
import Charts
import UniformTypeIdentifiers
import os

private let dashboardLogger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "Dashboard")

private struct MetricsGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct DashboardView: View {
    private var store: FundDataStore { .shared }
    private var cache: ViewCache { .shared }
    @State private var showCreateFund = false
    @State private var showImport = false
    @State private var showCharts = true
    @State private var platformFilter: String? = nil
    @State private var viewMode: ViewMode = .grid
    @State private var dismissedAlertIds: Set<String> = []
    @State private var collapsedDashPlatforms: Set<String> = []
    // Cached groupings, refreshed only on revision/platformFilter changes so
    // unrelated view invalidations (e.g. scrolling, nav) don't re-filter/re-group.
    @State private var activeSummaries: [FundSummary] = []
    @State private var closedSummaries: [FundSummary] = []
    @State private var activeSummariesByPlatform: [String: [FundSummary]] = [:]
    @State private var closedSummariesByPlatform: [String: [FundSummary]] = [:]
    @State private var filteredPortfolio = PortfolioMetrics()
    @State private var cashFundCount: Int = 0
    @State private var metricsGridWidth: CGFloat = 900
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

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case table = "Table"
    }

    private func refreshGroupings() {
        let allSummaries = store.summaries
        let filter = platformFilter
        var active: [FundSummary] = []
        var closed: [FundSummary] = []
        active.reserveCapacity(allSummaries.count)
        for s in allSummaries {
            if let filter, s.fund.platform != filter { continue }
            if s.fund.config.status == .closed { closed.append(s) } else { active.append(s) }
        }
        activeSummaries = active
        closedSummaries = closed
        activeSummariesByPlatform = Dictionary(grouping: active, by: { $0.fund.platform })
        closedSummariesByPlatform = Dictionary(grouping: closed, by: { $0.fund.platform })
        let allFiltered = active + closed
        filteredPortfolio = store.filteredPortfolio(platform: filter)
        cashFundCount = allFiltered.filter { $0.isCash }.count
    }

    var platforms: [String] { store.platforms }

    /// True when at least one fund has entry data worth showing metrics for
    private var hasEntryData: Bool {
        store.funds.contains { !$0.entries.isEmpty }
    }

    var body: some View {
        Group {
        #if os(macOS)
        macDashboard
        #else
        iosDashboard
            .navigationTitle("EscapeMint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { showCreateFund = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.mint)
                }
            }
            .sheet(isPresented: $showCreateFund) {
                CreateFundView {}
            }
        #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCreateFund)) { _ in
            showCreateFund = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fundsDidChange)) { _ in
            Task { await store.reload() }
        }
        .onChange(of: showCharts) { _, on in
            if on && cache.dashboardTimeSeries.isEmpty && store.isLoaded { recomputeChartsIfNeeded() }
            if !on { cache.cancelDashboard() }
        }
        .onChange(of: store.revision) { _, _ in
            refreshGroupings()
            guard store.isLoaded else { return }
            if showCharts && !store.funds.isEmpty { recomputeChartsIfNeeded() }
        }
        .onChange(of: store.isLoaded) { _, loaded in
            if loaded { refreshGroupings() }
            if loaded && showCharts && !store.funds.isEmpty { recomputeChartsIfNeeded() }
        }
        .onChange(of: platformFilter) { _, _ in refreshGroupings() }
        .onAppear {
            loadDashCollapsedState()
            refreshGroupings()
            if showCharts && store.isLoaded { recomputeChartsIfNeeded() }
        }
    }

    // MARK: - macOS Dashboard

    private func recomputeChartsIfNeeded() {
        cache.recomputeDashboardTimeSeries(funds: store.funds, revision: store.revision)
    }

    @ViewBuilder
    private var chartLoadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Computing charts\u{2026}").font(.caption).foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    @ViewBuilder
    private var loadingBanner: some View {
        if !store.isLoaded {
            EscapeMintLoadingBanner(
                message: store.loadingPhase.message,
                progress: store.funds.isEmpty ? nil : store.loadProgress,
                loadedCount: store.loadedFundCount,
                totalCount: store.funds.count
            )
        }
    }

    @ViewBuilder
    private var macDashboard: some View {
        ScrollView {
            VStack(spacing: 10) {
                dashboardHeader
                loadingBanner
                if !store.funds.isEmpty {
                    if store.isLoaded && !store.actionableFunds.isEmpty {
                        ActionableFundsBanner(actionableFunds: store.actionableFunds, dismissedIds: $dismissedAlertIds)
                    }
                    if hasEntryData {
                        metricsGrid
                    }
                }
                if showCharts && hasEntryData {
                    if cache.isComputingDashboard && cache.dashboardTimeSeries.isEmpty {
                        chartLoadingIndicator
                    } else {
                        dashboardCharts
                    }
                }
                toolbarRow
                fundList
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
    }

    // MARK: - iOS Dashboard

    @ViewBuilder
    private var iosDashboard: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !store.isLoaded {
                    loadingBanner.padding(.horizontal)
                }
                if !store.funds.isEmpty {
                    // iOS header controls
                    iosHeaderControls
                    if store.isLoaded && !store.actionableFunds.isEmpty {
                        ActionableFundsBanner(actionableFunds: store.actionableFunds, dismissedIds: $dismissedAlertIds)
                            .padding(.horizontal)
                    }
                    if hasEntryData {
                        iosMetricsGrid
                    }
                }
                if showCharts && hasEntryData {
                    if cache.isComputingDashboard && cache.dashboardTimeSeries.isEmpty {
                        chartLoadingIndicator
                    } else {
                        iosDashboardCharts
                    }
                }
                fundList
                    .padding(.horizontal)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg.ignoresSafeArea())
        #if os(iOS)
        .toolbarBackground(Color.bgCard, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .refreshable { await store.reload() }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                importFunds(from: url)
            }
        }
    }

    // MARK: - iOS Header Controls

    @ViewBuilder
    private var iosHeaderControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(filteredPortfolio.activeFunds) active \u{2022} \(filteredPortfolio.closedFunds) closed")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
                if hasEntryData {
                    Toggle(isOn: $showCharts) {
                        EmptyView()
                    }
                    .toggleStyle(.switch)
                    .tint(.mint)
                    .labelsHidden()
                    Text("Charts")
                        .font(.caption).foregroundColor(.textSecondary)
                }
            }
            if platforms.count > 1 {
                Picker("Platform", selection: $platformFilter) {
                    Text("All").tag(nil as String?)
                    ForEach(platforms, id: \.self) { p in
                        Text(p.capitalized).tag(p as String?)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: - iOS Metrics Grid

    @ViewBuilder
    private var iosMetricsGrid: some View {
        let p = filteredPortfolio
        let colCount = isWide ? 3 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: colCount)
        LazyVGrid(columns: columns, spacing: 8) {
            MetricCard(label: "Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(p.funds.count) funds")
            MetricCard(label: "Value", value: formatCurrency(p.totalValue), sub: "\(p.activeFunds) active")
            MetricCard(label: "Realized", value: formatCurrency(p.totalRealizedGains), color: p.totalRealizedGains > 0 ? .mint : .red)
            MetricCard(label: "R.APY", value: formatPercent(p.realizedAPY), color: p.realizedAPY > 0 ? .mint : .red)
            MetricCard(label: "Unrealized", value: formatCurrency(p.totalUnrealizedGains), color: p.totalUnrealizedGains >= 0 ? .mint : .red)
            MetricCard(label: "Liquid", value: formatCurrency(p.totalGainUsd), color: p.totalGainUsd >= 0 ? .mint : .red)
            MetricCard(label: "L.APY", value: formatPercent(p.liquidAPY), color: p.liquidAPY > 0 ? .mint : .red)
            MetricCard(label: "Projected", value: formatCurrency(p.projectedAnnualReturn), color: p.projectedAnnualReturn > 0 ? .mint : .red)
            MetricCard(label: "Cash", value: formatCurrency(p.cashBalance), sub: "\(cashFundCount) cash funds")
            MetricCard(label: "Interest", value: formatCurrency(p.totalInterest), sub: "Earned to date")
        }
        .padding(.horizontal)
    }

    // MARK: - iOS Dashboard Charts

    @ViewBuilder
    private var iosDashboardCharts: some View {
        let hasActive = !activeSummaries.isEmpty
        VStack(spacing: 12) {
            if isWide {
                // iPad: pie charts in a row (only when there are active funds)
                if hasActive {
                    HStack(alignment: .top, spacing: 8) {
                        FundAllocationChart(summaries: activeSummaries)
                        PortfolioAllocationChart(summaries: activeSummaries)
                        PlatformAllocationChart(summaries: activeSummaries)
                    }
                }
                // iPad: time series in 2-column grid
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    DashboardAPYChart(points: cache.dashboardTimeSeries)
                    DashboardGainChart(points: cache.dashboardTimeSeries)
                    DashboardFundSizeChart(points: cache.dashboardTimeSeries)
                    DashboardLiquidValueChart(points: cache.dashboardTimeSeries)
                    DashboardValueChart(points: cache.dashboardTimeSeries)
                    DashboardMarginChart(points: cache.dashboardTimeSeries)
                    DashboardCashVsAssetChart(points: cache.dashboardTimeSeries)
                }
            } else {
                // iPhone: single column
                if hasActive {
                    FundAllocationChart(summaries: activeSummaries)
                    PortfolioAllocationChart(summaries: activeSummaries)
                    PlatformAllocationChart(summaries: activeSummaries)
                }
                DashboardAPYChart(points: cache.dashboardTimeSeries)
                DashboardGainChart(points: cache.dashboardTimeSeries)
                DashboardFundSizeChart(points: cache.dashboardTimeSeries)
                DashboardLiquidValueChart(points: cache.dashboardTimeSeries)
                DashboardValueChart(points: cache.dashboardTimeSeries)
                DashboardMarginChart(points: cache.dashboardTimeSeries)
                DashboardCashVsAssetChart(points: cache.dashboardTimeSeries)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Dashboard Header

    @ViewBuilder
    private var dashboardHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundColor(.textPrimary)
                if !store.funds.isEmpty {
                    Text("\(filteredPortfolio.activeFunds) active \u{2022} \(filteredPortfolio.closedFunds) closed")
                        .font(.subheadline).foregroundColor(.textSecondary)
                }
            }

            Spacer()

            ViewThatFits(in: .horizontal) {
                headerControls(compact: false)
                headerControls(compact: true)
            }
            .sheet(isPresented: $showCreateFund) {
                CreateFundView {}
            }
        }
    }

    @ViewBuilder
    private func headerControls(compact: Bool) -> some View {
        HStack {
            if !store.funds.isEmpty {
                // Charts toggle
                Toggle(isOn: $showCharts) {
                    if !compact {
                        Text("Charts")
                            .font(.callout).foregroundColor(.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(.mint)
                .frame(width: compact ? nil : 110)
                .help("Show charts")
            }

            // Platform filter
            if platforms.count > 1 {
                Picker("Platform", selection: $platformFilter) {
                    Text("All").tag(nil as String?)
                    ForEach(platforms, id: \.self) { p in
                        Text(p.capitalized).tag(p as String?)
                    }
                }
                .labelsHidden()
                .frame(minWidth: compact ? nil : 150)
            }

            // Add Fund
            Button { showCreateFund = true } label: {
                if compact {
                    Image(systemName: "plus.circle.fill")
                        .font(.callout)
                } else {
                    Label("Add Fund", systemImage: "plus.circle.fill")
                        .font(.callout).fontWeight(.medium)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .help("Add Fund")
        }
    }

    // MARK: - Metrics Grid (macOS)

    @ViewBuilder
    private var metricsGrid: some View {
        let p = filteredPortfolio
        let fundCount = p.funds.count
        let avgDays = fundCount > 0 ? p.totalDaysActive / fundCount : 0
        let unrealizedPct = p.totalStartInput > 0 ? p.totalUnrealizedGains / p.totalStartInput : 0
        let liquidPct = p.totalStartInput > 0 ? p.totalGainUsd / p.totalStartInput : 0
        let hasCash = p.cashBalance > 0.01
        let fullColCount = hasCash ? 9 : 8
        // Narrow detail panes (e.g. Stage Manager) squeeze ~62pt cards that truncate
        // every value; step the column count down so cards stay legible.
        let colCount = metricsGridWidth >= 900 ? fullColCount : (metricsGridWidth >= 600 ? 4 : 2)
        metricsGridContent(p: p, fundCount: fundCount, avgDays: avgDays, unrealizedPct: unrealizedPct, liquidPct: liquidPct, hasCash: hasCash, colCount: colCount)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: MetricsGridWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(MetricsGridWidthKey.self) { metricsGridWidth = $0 }
    }

    @ViewBuilder
    private func metricsGridContent(p: PortfolioMetrics, fundCount: Int, avgDays: Int, unrealizedPct: Double, liquidPct: Double, hasCash: Bool, colCount: Int) -> some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 10), count: colCount), spacing: 10) {
            MetricCard(label: "Total Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(fundCount) funds", tooltip: "Total capital allocated across all funds")
            MetricCard(label: "Current Value", value: formatCurrency(p.totalValue), sub: "\(p.activeFunds) active", tooltip: "Current market value of all positions")
            MetricCard(label: "Realized Gain", value: formatCurrency(p.totalRealizedGains), sub: "Divs + Interest + Sells", color: p.totalRealizedGains > 0 ? .mint : .red, tooltip: "Profits already extracted: dividends, interest, and sell profits minus expenses")
            MetricCard(label: "Realized APY", value: formatPercentSigned(p.realizedAPY), sub: "\(avgDays) avg days", color: p.realizedAPY > 0 ? .mint : .red, tooltip: "Annualized realized return. Time-Weighted Fund Size: \(formatCurrency(p.totalTimeWeightedFundSize))")
            MetricCard(label: "Unrealized Gain", value: formatCurrency(p.totalUnrealizedGains), sub: formatPercentSigned(unrealizedPct), color: p.totalUnrealizedGains >= 0 ? .mint : .red, tooltip: "Paper gains: Current Value minus Cost Basis (not yet realized)")
            MetricCard(label: "Liquid Gain", value: formatCurrency(p.totalGainUsd), sub: formatPercentSigned(liquidPct), color: p.totalGainUsd >= 0 ? .mint : .red, tooltip: "Total lifetime gain: Unrealized + Realized (if liquidated now)")
            MetricCard(label: "Liquid APY", value: formatPercentSigned(p.liquidAPY), sub: "If liquidated now", color: p.liquidAPY > 0 ? .mint : .red, tooltip: "Annualized return based on total liquid gain")
            MetricCard(label: "Projected Annual", value: formatCurrency(p.projectedAnnualReturn), sub: "Based on realized APY", color: p.projectedAnnualReturn > 0 ? .mint : .red, tooltip: "Expected annual return if current realized APY continues")
            if hasCash {
                MetricCard(label: "Cash Balance", value: formatCurrency(p.cashBalance), sub: "Interest: \(formatCurrency(p.totalInterest))", tooltip: "Total cash across \(cashFundCount) platform cash funds")
            }
        }
    }

    // MARK: - Dashboard Charts

    @ViewBuilder
    private var dashboardCharts: some View {
        // Allocation pie charts row (only when there are active funds)
        if !activeSummaries.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                FundAllocationChart(summaries: activeSummaries)
                PortfolioAllocationChart(summaries: activeSummaries)
                PlatformAllocationChart(summaries: activeSummaries)
            }
        }

        // Time series charts — adaptive grid so columns reflow on narrow detail panes
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], spacing: 8) {
            DashboardAPYChart(points: cache.dashboardTimeSeries)
            DashboardGainChart(points: cache.dashboardTimeSeries)
            DashboardFundSizeChart(points: cache.dashboardTimeSeries)
            DashboardLiquidValueChart(points: cache.dashboardTimeSeries)
            DashboardValueChart(points: cache.dashboardTimeSeries)
            DashboardMarginChart(points: cache.dashboardTimeSeries)
            DashboardCashVsAssetChart(points: cache.dashboardTimeSeries)
        }
    }

    // MARK: - Toolbar Row

    @ViewBuilder
    private var toolbarRow: some View {
        HStack {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Spacer()
        }
    }

    // MARK: - Fund List

    @ViewBuilder
    private var fundList: some View {
        if viewMode == .table {
            fundTable
        } else {
            fundCards
        }
    }

    @ViewBuilder
    private var fundCards: some View {
        let grouped = activeSummariesByPlatform
        ForEach(grouped.keys.sorted(), id: \.self) { platform in
            if let platformFunds = grouped[platform] {
                Section {
                    if !isDashCollapsed(platform, closed: false) {
                        #if os(macOS)
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, min(3, activeSummaries.count)))
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(platformFunds, id: \.fund.id) { summary in
                                FundCardView(summary: summary)
                                    .onTapGesture { navigateToFund(summary.fund.id) }
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        #else
                        if isWide {
                            LazyVGrid(columns: [.init(.flexible(), spacing: 10), .init(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(platformFunds, id: \.fund.id) { summary in
                                    NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                        FundCardView(summary: summary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            ForEach(platformFunds, id: \.fund.id) { summary in
                                NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                    FundCardView(summary: summary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        #endif
                    }
                } header: {
                    HStack {
                        Image(systemName: isDashCollapsed(platform, closed: false) ? "chevron.right" : "chevron.down")
                            .font(.caption2).foregroundColor(.textMuted)
                            .frame(width: 12)
                        Text(platform.capitalized)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text("\(platformFunds.count) funds")
                            .font(.caption2).foregroundColor(.textMuted)
                    }
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleDashPlatform(platform, closed: false) }
                    .accessibilityAddTraits(.isButton)
                }
            }
        }

        if !closedSummaries.isEmpty {
            ForEach(closedSummariesByPlatform.keys.sorted(), id: \.self) { platform in
                if let platformFunds = closedSummariesByPlatform[platform] {
                    Section {
                        if !isDashCollapsed(platform, closed: true) {
                            #if os(macOS)
                            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, min(3, platformFunds.count)))
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(platformFunds, id: \.fund.id) { summary in
                                    FundCardView(summary: summary)
                                        .onTapGesture { navigateToFund(summary.fund.id) }
                                        .accessibilityAddTraits(.isButton)
                                }
                            }
                            #else
                            if isWide {
                                LazyVGrid(columns: [.init(.flexible(), spacing: 10), .init(.flexible(), spacing: 10)], spacing: 10) {
                                    ForEach(platformFunds, id: \.fund.id) { summary in
                                        NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                            FundCardView(summary: summary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else {
                                ForEach(platformFunds, id: \.fund.id) { summary in
                                    NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                        FundCardView(summary: summary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            #endif
                        }
                    } header: {
                        HStack {
                            Image(systemName: isDashCollapsed(platform, closed: true) ? "chevron.right" : "chevron.down")
                                .font(.caption2).foregroundColor(.textMuted)
                                .frame(width: 12)
                            Text("\(platform.capitalized) (Closed)")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundColor(.textMuted)
                            Spacer()
                            Text("\(platformFunds.count) funds")
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleDashPlatform(platform, closed: true) }
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }

        emptyState
    }

    @ViewBuilder
    private var fundTable: some View {
        if !activeSummaries.isEmpty {
            let cols = tableColumns
            VStack(spacing: 0) {
                // Header
                Grid(horizontalSpacing: 8) {
                    GridRow {
                        ForEach(cols, id: \.label) { col in
                            Text(col.label)
                                .frame(maxWidth: .infinity, alignment: col.alignment)
                        }
                    }
                }
                .font(.caption2).fontWeight(.semibold)
                .foregroundColor(.textMuted)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.bgInput.opacity(0.5))

                ForEach(activeSummaries, id: \.fund.id) { s in
                    Grid(horizontalSpacing: 8) {
                        GridRow {
                            Text(s.fund.ticker.uppercased()).fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.fund.platform)
                                .foregroundColor(.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.features.label)
                                .foregroundColor(.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatCurrency(s.metrics.fundSize))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.currentValue))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.metrics.realizedGains))
                                .foregroundColor(s.metrics.realizedGains > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("Realized \(gainLossWord(s.metrics.realizedGains)) \(formatCurrency(s.metrics.realizedGains))")
                            Text(formatPercent(s.realizedAPY))
                                .foregroundColor(s.realizedAPY > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("Realized APY \(gainLossWord(s.realizedAPY)) \(formatPercent(s.realizedAPY))")
                            Text(formatCurrency(s.liquidGain))
                                .foregroundColor(s.liquidGain >= 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("Liquid \(gainLossWord(s.liquidGain)) \(formatCurrency(s.liquidGain))")
                            Text(formatPercent(s.liquidAPY))
                                .foregroundColor(s.liquidAPY > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("Liquid APY \(gainLossWord(s.liquidAPY)) \(formatPercent(s.liquidAPY))")
                            Text("\(s.fund.entries.count)")
                                .foregroundColor(.textMuted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.bgCard)
                    .contentShape(Rectangle())
                    .onTapGesture { navigateToFund(s.fund.id) }
                    .accessibilityAddTraits(.isButton)

                    Divider().background(Color.bgInput)
                }
            }
            .cornerRadius(8)
        }
    }

    // Conveys the color-coded gain/loss state to VoiceOver, which can't perceive the tint.
    private func gainLossWord(_ value: Double) -> String {
        value >= 0 ? "gain" : "loss"
    }

    private var tableColumns: [(label: String, alignment: Alignment)] {
        [
            ("Fund", .leading), ("Platform", .leading), ("Type", .leading),
            ("Size", .trailing), ("Value", .trailing), ("Realized", .trailing),
            ("R.APY", .trailing), ("Liquid", .trailing), ("L.APY", .trailing),
            ("Entries", .trailing)
        ]
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.funds.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "leaf.fill")
                    .font(.largeTitle).foregroundColor(.mint)
                    .accessibilityHidden(true)
                Text("No funds yet")
                    .font(.title2).fontWeight(.semibold).foregroundColor(.textPrimary)
                Text("Create your first fund, or import a backup from the EscapeMint web app.")
                    .font(.subheadline).foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { showCreateFund = true } label: {
                        Label("Add Fund", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                    Button { pickAndImport() } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .tint(.textSecondary)
                }
                .padding(.top, 4)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    // MARK: - Platform Collapse

    private func dashPlatformKey(_ platform: String, closed: Bool) -> String {
        "\(closed ? "closed" : "active"):\(platform)"
    }

    private func isDashCollapsed(_ platform: String, closed: Bool) -> Bool {
        collapsedDashPlatforms.contains(dashPlatformKey(platform, closed: closed))
    }

    private func toggleDashPlatform(_ platform: String, closed: Bool) {
        let key = dashPlatformKey(platform, closed: closed)
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedDashPlatforms.contains(key) {
                collapsedDashPlatforms.remove(key)
            } else {
                collapsedDashPlatforms.insert(key)
            }
        }
        UserDefaults.standard.set(Array(collapsedDashPlatforms), forKey: AppStorageKeys.dashboardCollapsed)
    }

    private func loadDashCollapsedState() {
        if let saved = UserDefaults.standard.stringArray(forKey: AppStorageKeys.dashboardCollapsed) {
            collapsedDashPlatforms = Set(saved)
        } else {
            let closedGrouped = Dictionary(grouping: closedSummaries, by: { $0.fund.platform })
            for platform in closedGrouped.keys {
                collapsedDashPlatforms.insert(dashPlatformKey(platform, closed: true))
            }
            UserDefaults.standard.set(Array(collapsedDashPlatforms), forKey: AppStorageKeys.dashboardCollapsed)
        }
    }

    // MARK: - Actions

    private func pickAndImport() {
        #if os(macOS)
        showOpenPanel(
            title: "Select funds directory",
            message: "Choose the folder containing your .tsv and .json fund files",
            canChooseFiles: false,
            canChooseDirectories: true,
            allowedContentTypes: [],
            canCreateDirectories: false,
            treatsFilePackagesAsDirectories: true
        ) { url in
            self.importFunds(from: url)
        }
        #else
        showImport = true
        #endif
    }

    private func importFunds(from url: URL) {
        Task {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try await FundStore.shared.importFromDirectory(url)
                if count > 0 { await store.reload() }
            } catch {
                dashboardLogger.error("Import failed: \(error.localizedDescription)")
            }
        }
    }

    private func navigateToFund(_ id: String) {
        #if os(macOS)
        NotificationCenter.default.post(name: .selectFund, object: id)
        #endif
    }

    private func navigateToPlatform(_ platform: String) {
        #if os(macOS)
        NotificationCenter.default.post(name: .selectPlatform, object: platform)
        #endif
    }
}
