import SwiftUI
import Charts

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

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case table = "Table"
    }

    var activeSummaries: [FundSummary] {
        let active = store.summaries.filter { $0.fund.config.status != .closed }
        guard let filter = platformFilter else { return active }
        return active.filter { $0.fund.platform == filter }
    }

    var closedSummaries: [FundSummary] {
        let closed = store.summaries.filter { $0.fund.config.status == .closed }
        guard let filter = platformFilter else { return closed }
        return closed.filter { $0.fund.platform == filter }
    }

    var platforms: [String] { store.platforms }

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
                CreateFundView { Task { await store.reload() } }
            }
        #endif
        }
        .onChange(of: showCharts) { _, on in
            if on && cache.dashboardTimeSeries.isEmpty && store.isLoaded { recomputeChartsIfNeeded() }
            if !on { cache.cancelDashboard() }
        }
        .onChange(of: store.revision) { _, _ in
            guard store.isLoaded else { return }
            if showCharts && !store.funds.isEmpty { recomputeChartsIfNeeded() }
        }
        .onAppear {
            loadDashCollapsedState()
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
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading fund data\u{2026} \(store.loadedFundCount)/\(store.funds.count)")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
                ProgressView(value: store.loadProgress)
                    .frame(width: 120)
                    .tint(.mint)
            }
            .padding(10)
            .background(Color.bgCard)
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var macDashboard: some View {
        ScrollView {
            VStack(spacing: 16) {
                dashboardHeader
                loadingBanner
                if !store.actionableFunds.isEmpty {
                    ActionableFundsBanner(actionableFunds: store.actionableFunds, dismissedIds: $dismissedAlertIds)
                }
                metricsGrid
                if showCharts && !store.funds.isEmpty {
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
                // iOS header controls
                iosHeaderControls
                if !store.isLoaded {
                    loadingBanner.padding(.horizontal)
                }
                if !store.actionableFunds.isEmpty {
                    ActionableFundsBanner(actionableFunds: store.actionableFunds, dismissedIds: $dismissedAlertIds)
                        .padding(.horizontal)
                }
                iosMetricsGrid
                if showCharts && !store.funds.isEmpty {
                    if cache.isComputingDashboard && cache.dashboardTimeSeries.isEmpty {
                        chartLoadingIndicator
                    } else {
                        iosDashboardCharts
                    }
                }
                fundList
                emptyState
            }
            .padding(.bottom, 32)
        }
        .background(Color.bg.ignoresSafeArea())
        #if os(iOS)
        .toolbarBackground(Color.bgCard, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .refreshable { await store.reload() }
    }

    // MARK: - iOS Header Controls

    @ViewBuilder
    private var iosHeaderControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(store.portfolio.activeFunds) active \u{2022} \(store.portfolio.closedFunds) closed")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
                Toggle(isOn: $showCharts) {
                    Text("Charts")
                        .font(.caption).foregroundColor(.textSecondary)
                }
                .toggleStyle(.switch)
                .tint(.mint)
                .frame(minWidth: 100)
            }
            if platforms.count > 1 {
                Picker("Platform", selection: $platformFilter) {
                    Text("All Platforms").tag(nil as String?)
                    ForEach(platforms, id: \.self) { p in
                        Text(p.capitalized).tag(p as String?)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - iOS Metrics Grid (2-col)

    @ViewBuilder
    private var iosMetricsGrid: some View {
        let p = store.portfolio
        LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
            MetricCard(label: "Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(store.funds.count) funds")
            MetricCard(label: "Value", value: formatCurrency(p.totalValue), sub: "\(p.activeFunds) active")
            MetricCard(label: "Realized", value: formatCurrency(p.totalRealizedGains), color: p.totalRealizedGains > 0 ? .mint : .red)
            MetricCard(label: "R.APY", value: formatPercent(p.realizedAPY), color: p.realizedAPY > 0 ? .mint : .red)
            MetricCard(label: "Unrealized", value: formatCurrency(p.totalUnrealizedGains), color: p.totalUnrealizedGains >= 0 ? .mint : .red)
            MetricCard(label: "Liquid", value: formatCurrency(p.totalGainUsd), color: p.totalGainUsd >= 0 ? .mint : .red)
            MetricCard(label: "L.APY", value: formatPercent(p.liquidAPY), color: p.liquidAPY > 0 ? .mint : .red)
            MetricCard(label: "Projected", value: formatCurrency(p.projectedAnnualReturn), color: p.projectedAnnualReturn > 0 ? .mint : .red)
            MetricCard(label: "Cash", value: formatCurrency(p.cashBalance), sub: "Int: \(formatCurrency(p.totalInterest))")
        }
        .padding(.horizontal)
    }

    // MARK: - iOS Dashboard Charts

    @ViewBuilder
    private var iosDashboardCharts: some View {
        VStack(spacing: 12) {
            // Allocation pie charts
            FundAllocationChart(summaries: activeSummaries)
            PortfolioAllocationChart(summaries: activeSummaries)
            PlatformAllocationChart(summaries: activeSummaries)
            // Time series
            DashboardAPYChart(points: cache.dashboardTimeSeries)
            DashboardGainChart(points: cache.dashboardTimeSeries)
            DashboardValueChart(points: cache.dashboardTimeSeries)
            DashboardFundSizeChart(points: cache.dashboardTimeSeries)
            DashboardLiquidValueChart(points: cache.dashboardTimeSeries)
            DashboardMarginChart(points: cache.dashboardTimeSeries)
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
                Text("\(store.portfolio.activeFunds) active \u{2022} \(store.portfolio.closedFunds) closed")
                    .font(.subheadline).foregroundColor(.textSecondary)
            }

            Spacer()

            // Charts toggle
            Toggle(isOn: $showCharts) {
                Text("Charts")
                    .font(.callout).foregroundColor(.textSecondary)
            }
            .toggleStyle(.switch)
            .tint(.mint)
            .frame(width: 110)

            // Platform filter
            if platforms.count > 1 {
                Picker("Platform", selection: $platformFilter) {
                    Text("All Platforms").tag(nil as String?)
                    ForEach(platforms, id: \.self) { p in
                        Text(p.capitalized).tag(p as String?)
                    }
                }
                .frame(minWidth: 150)
            }

            // Import
            Button { pickAndImport() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .foregroundColor(.textSecondary)
            }
            .buttonStyle(.plain)

            // Add Fund
            Button { showCreateFund = true } label: {
                Label("Add Fund", systemImage: "plus.circle.fill")
                    .font(.callout).fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .sheet(isPresented: $showCreateFund) {
                CreateFundView { Task { await store.reload() } }
            }
        }
    }

    // MARK: - Metrics Grid (macOS)

    @ViewBuilder
    private var metricsGrid: some View {
        let p = store.portfolio
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 10), count: 5), spacing: 10) {
            MetricCard(label: "Total Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(store.funds.count) funds")
            MetricCard(label: "Current Value", value: formatCurrency(p.totalValue), sub: "\(p.activeFunds) active")
            MetricCard(label: "Realized Gain", value: formatCurrency(p.totalRealizedGains), color: p.totalRealizedGains > 0 ? .mint : .red)
            MetricCard(label: "Realized APY", value: formatPercent(p.realizedAPY), color: p.realizedAPY > 0 ? .mint : .red)
            MetricCard(label: "Unrealized Gain", value: formatCurrency(p.totalUnrealizedGains), color: p.totalUnrealizedGains >= 0 ? .mint : .red)
            MetricCard(label: "Liquid Gain", value: formatCurrency(p.totalGainUsd), color: p.totalGainUsd >= 0 ? .mint : .red)
            MetricCard(label: "Liquid APY", value: formatPercent(p.liquidAPY), color: p.liquidAPY > 0 ? .mint : .red)
            MetricCard(label: "Projected Annual", value: formatCurrency(p.projectedAnnualReturn), color: p.projectedAnnualReturn > 0 ? .mint : .red)
            MetricCard(label: "Cash Balance", value: formatCurrency(p.cashBalance), sub: "Int: \(formatCurrency(p.totalInterest))")
        }
    }

    // MARK: - Dashboard Charts

    @ViewBuilder
    private var dashboardCharts: some View {
        // Allocation pie charts row
        HStack(alignment: .top, spacing: 12) {
            FundAllocationChart(summaries: activeSummaries)
            PortfolioAllocationChart(summaries: activeSummaries)
            PlatformAllocationChart(summaries: activeSummaries)
        }

        // Time series charts — 2-column grid
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            DashboardAPYChart(points: cache.dashboardTimeSeries)
            DashboardGainChart(points: cache.dashboardTimeSeries)
            DashboardValueChart(points: cache.dashboardTimeSeries)
            DashboardFundSizeChart(points: cache.dashboardTimeSeries)
            DashboardLiquidValueChart(points: cache.dashboardTimeSeries)
            DashboardMarginChart(points: cache.dashboardTimeSeries)
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
        let grouped = Dictionary(grouping: activeSummaries, by: { $0.fund.platform })
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
                            }
                        }
                        #else
                        ForEach(platformFunds, id: \.fund.id) { summary in
                            NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                FundCardView(summary: summary)
                            }
                            .buttonStyle(.plain)
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
                }
            }
        }

        if !closedSummaries.isEmpty {
            let closedGrouped = Dictionary(grouping: closedSummaries, by: { $0.fund.platform })
            ForEach(closedGrouped.keys.sorted(), id: \.self) { platform in
                if let platformFunds = closedGrouped[platform] {
                    Section {
                        if !isDashCollapsed(platform, closed: true) {
                            #if os(macOS)
                            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, min(3, platformFunds.count)))
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(platformFunds, id: \.fund.id) { summary in
                                    FundCardView(summary: summary)
                                        .onTapGesture { navigateToFund(summary.fund.id) }
                                }
                            }
                            #else
                            ForEach(platformFunds, id: \.fund.id) { summary in
                                NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                    FundCardView(summary: summary)
                                }
                                .buttonStyle(.plain)
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
                            Text(formatPercent(s.realizedAPY))
                                .foregroundColor(s.realizedAPY > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.liquidGain))
                                .foregroundColor(s.liquidGain >= 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatPercent(s.liquidAPY))
                                .foregroundColor(s.liquidAPY > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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

                    Divider().background(Color.bgInput)
                }
            }
            .cornerRadius(8)
        }
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
                Image(systemName: "leaf.fill")
                    .font(.largeTitle).foregroundColor(.mint)
                    .accessibilityHidden(true)
                Text("No funds yet")
                    .font(.title2).fontWeight(.semibold).foregroundColor(.textPrimary)
                Text("Create a fund or import from your web app's data/funds/ directory")
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
            }
            .padding(.top, 60)
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
        UserDefaults.standard.set(Array(collapsedDashPlatforms), forKey: "escapemint-dashboard-collapsed")
    }

    private func loadDashCollapsedState() {
        if let saved = UserDefaults.standard.stringArray(forKey: "escapemint-dashboard-collapsed") {
            collapsedDashPlatforms = Set(saved)
        } else {
            let closedGrouped = Dictionary(grouping: closedSummaries, by: { $0.fund.platform })
            for platform in closedGrouped.keys {
                collapsedDashPlatforms.insert(dashPlatformKey(platform, closed: true))
            }
            UserDefaults.standard.set(Array(collapsedDashPlatforms), forKey: "escapemint-dashboard-collapsed")
        }
    }

    // MARK: - Actions

    private func pickAndImport() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Select funds directory"
        panel.message = "Choose the folder containing your .tsv and .json fund files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        guard let window = NSApp.keyWindow else {
            if panel.runModal() == .OK, let url = panel.url {
                importFunds(from: url)
            }
            return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.importFunds(from: url)
            }
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
                print("Import failed: \(error.localizedDescription)")
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

