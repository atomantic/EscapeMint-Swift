import SwiftUI
import Charts

struct DashboardView: View {
    @State private var funds: [FundData] = []
    @State private var summaries: [FundSummary] = []
    @State private var portfolio = PortfolioMetrics()
    @State private var showCreateFund = false
    @State private var showImport = false
    @State private var showCharts = false
    @State private var platformFilter: String? = nil
    @State private var viewMode: ViewMode = .grid
    @State private var actionableFunds: [ActionableFund] = []
    @State private var dismissedAlertIds: Set<String> = []

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case table = "Table"
    }

    var activeSummaries: [FundSummary] {
        let active = summaries.filter { $0.fund.config.status != .closed }
        guard let filter = platformFilter else { return active }
        return active.filter { $0.fund.platform == filter }
    }

    var closedSummaries: [FundSummary] {
        let closed = summaries.filter { $0.fund.config.status == .closed }
        guard let filter = platformFilter else { return closed }
        return closed.filter { $0.fund.platform == filter }
    }

    var platforms: [String] {
        Array(Set(funds.map(\.platform))).sorted()
    }

    var body: some View {
        #if os(macOS)
        macDashboard
        #else
        iosDashboard
            .navigationTitle("EscapeMint")
            .toolbar {
                Button { showCreateFund = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.mint)
                }
            }
            .sheet(isPresented: $showCreateFund) {
                CreateFundView { loadFunds() }
            }
        #endif
    }

    // MARK: - macOS Dashboard

    @ViewBuilder
    private var macDashboard: some View {
        ScrollView {
            VStack(spacing: 16) {
                dashboardHeader
                if !actionableFunds.isEmpty {
                    ActionableFundsBanner(actionableFunds: actionableFunds, dismissedIds: $dismissedAlertIds)
                }
                metricsGrid
                if showCharts && !funds.isEmpty {
                    dashboardCharts
                }
                toolbarRow
                fundList
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        .task { loadFunds() }
        .onReceive(NotificationCenter.default.publisher(for: .fundsDidChange)) { _ in
            loadFunds()
        }
    }

    // MARK: - iOS Dashboard

    @ViewBuilder
    private var iosDashboard: some View {
        ScrollView {
            VStack(spacing: 12) {
                // iOS header controls
                iosHeaderControls
                if !actionableFunds.isEmpty {
                    ActionableFundsBanner(actionableFunds: actionableFunds, dismissedIds: $dismissedAlertIds)
                        .padding(.horizontal)
                }
                iosMetricsGrid
                if showCharts && !funds.isEmpty {
                    iosDashboardCharts
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
        .task { loadFunds() }
        .refreshable { loadFunds() }
        .onReceive(NotificationCenter.default.publisher(for: .fundsDidChange)) { _ in
            loadFunds()
        }
    }

    // MARK: - iOS Header Controls

    @ViewBuilder
    private var iosHeaderControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(portfolio.activeFunds) active \u{2022} \(portfolio.closedFunds) closed")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
                Button { showCharts.toggle() } label: {
                    Image(systemName: showCharts ? "chart.bar.fill" : "chart.bar")
                        .foregroundColor(showCharts ? .mint : .textMuted)
                }
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
        let p = portfolio
        LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
            MetricCard(label: "Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(funds.count) funds")
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
            // Allocation pie charts (vertical stack on mobile)
            FundAllocationChart(summaries: activeSummaries)
            PortfolioAllocationChart(summaries: activeSummaries)
            PlatformAllocationChart(summaries: activeSummaries)
            // Time series
            DashboardAPYChart(funds: funds)
            DashboardGainChart(funds: funds)
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
                Text("\(portfolio.activeFunds) active \u{2022} \(portfolio.closedFunds) closed")
                    .font(.subheadline).foregroundColor(.textSecondary)
            }

            Spacer()

            // Charts toggle
            Button { showCharts.toggle() } label: {
                Image(systemName: showCharts ? "chart.bar.fill" : "chart.bar")
                    .foregroundColor(showCharts ? .mint : .textMuted)
            }
            .buttonStyle(.plain)

            // Platform filter
            if platforms.count > 1 {
                Picker("Platform", selection: $platformFilter) {
                    Text("All Platforms").tag(nil as String?)
                    ForEach(platforms, id: \.self) { p in
                        Text(p.capitalized).tag(p as String?)
                    }
                }
                .frame(width: 150)
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
                CreateFundView { loadFunds() }
            }
        }
    }

    // MARK: - Metrics Grid (macOS)

    @ViewBuilder
    private var metricsGrid: some View {
        let p = portfolio
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 10), count: 5), spacing: 10) {
            MetricCard(label: "Total Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(funds.count) funds")
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

    // MARK: - Metrics Scroll (iOS)

    @ViewBuilder
    private var metricsScroll: some View {
        let p = portfolio
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MetricCard(label: "Fund Size", value: formatCurrency(p.totalFundSize), sub: "\(funds.count) funds")
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

        // Time series charts row
        HStack(alignment: .top, spacing: 12) {
            DashboardAPYChart(funds: funds)
            DashboardGainChart(funds: funds)
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
            Section {
                #if os(macOS)
                let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, min(3, activeSummaries.count)))
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(grouped[platform]!, id: \.fund.id) { summary in
                        FundCardView(summary: summary)
                            .onTapGesture { navigateToFund(summary.fund.id) }
                    }
                }
                #else
                ForEach(grouped[platform]!, id: \.fund.id) { summary in
                    NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                        FundCardView(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
                #endif
            } header: {
                HStack {
                    Text(platform.capitalized)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text("\(grouped[platform]!.count) funds")
                        .font(.caption2).foregroundColor(.textMuted)
                }
                .padding(.top, 8)
                .contentShape(Rectangle())
                .onTapGesture { navigateToPlatform(platform) }
            }
        }

        if !closedSummaries.isEmpty {
            Section {
                #if os(macOS)
                let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, min(3, closedSummaries.count)))
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(closedSummaries, id: \.fund.id) { summary in
                        FundCardView(summary: summary)
                            .onTapGesture { navigateToFund(summary.fund.id) }
                    }
                }
                #else
                ForEach(closedSummaries, id: \.fund.id) { summary in
                    NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                        FundCardView(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
                #endif
            } header: {
                Text("Closed")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(.textSecondary)
                    .padding(.top, 8)
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
                            Text(formatCurrency(s.fund.config.fund_size_usd ?? 0))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.currentValue))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.state.realizedGainsUsd))
                                .foregroundColor(s.state.realizedGainsUsd > 0 ? .mint : .red)
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
        if funds.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(.largeTitle).foregroundColor(.mint)
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

    // MARK: - Actions

    private func loadFunds() {
        Task {
            funds = await FundStore.shared.readAllFunds()
            // Compute portfolio first (single pass over all funds)
            portfolio = computePortfolioMetrics(funds)
            // Build summaries from pre-computed portfolio data instead of recomputing
            summaries = computeSummariesFromPortfolio(funds: funds, portfolio: portfolio)
                .sorted { $0.currentValue > $1.currentValue }
            actionableFunds = computeActionableFunds(funds)
            updateDockBadge(actionableFunds.count)
        }
    }

    private func updateDockBadge(_ count: Int) {
        #if os(macOS)
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        #endif
    }

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
            let count = try? await FundStore.shared.importFromDirectory(url)
            if (count ?? 0) > 0 {
                loadFunds()
                notifyFundsChanged()
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

// MARK: - Notifications
extension Notification.Name {
    static let selectFund = Notification.Name("selectFund")
    static let fundsDidChange = Notification.Name("fundsDidChange")
    static let selectPlatform = Notification.Name("selectPlatform")
}

func notifyFundsChanged() {
    NotificationCenter.default.post(name: .fundsDidChange, object: nil)
}

// MARK: - Subviews

struct MetricCard: View {
    let label: String
    let value: String
    var sub: String? = nil
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.bold).foregroundColor(color ?? .textPrimary)
            if let sub { Text(sub).font(.caption2).foregroundColor(.textMuted) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .cornerRadius(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(sub.map { ", \($0)" } ?? "")")
        .accessibilityIdentifier("metric-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

struct FundCardView: View {
    let summary: FundSummary

    var body: some View {
        let fund = summary.fund
        let value = summary.currentValue
        let state = summary.state
        let rec = summary.recommendation
        let features = summary.features
        let realizedAPY = summary.realizedAPY
        let liquidAPY = summary.liquidAPY

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(Color.forCategory(fund.config.category))
                    .frame(width: 8, height: 8)
                Text(fund.ticker.uppercased())
                    .font(.headline).foregroundColor(.textPrimary)
                Text(features.label)
                    .font(.caption2).foregroundColor(.textMuted)
                if fund.config.status == .closed {
                    Text("Closed").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.bgInput).cornerRadius(4)
                        .foregroundColor(.textMuted)
                }
                if summary.fundSharesPct > 0 {
                    Text(formatPercent(summary.fundSharesPct))
                        .font(.caption2).foregroundColor(.textMuted)
                }
                Spacer()
                if let rec {
                    Text("\(rec.action.rawValue) \(formatCurrency(rec.amount))")
                        .font(.caption2).fontWeight(.semibold).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(rec.action == .BUY ? Color.mintDark : rec.action == .SELL ? Color.red : Color.bgInput)
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 12) {
                if summary.isCash {
                    VStack(alignment: .leading) {
                        Text("Balance").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(value)).font(.caption).foregroundColor(.textPrimary)
                    }
                    VStack(alignment: .leading) {
                        Text("Interest").font(.caption2).foregroundColor(.textMuted)
                        Text("+\(formatCurrency(state.cashInterestUsd))").font(.caption).foregroundColor(.mint)
                    }
                    VStack(alignment: .leading) {
                        Text("APY").font(.caption2).foregroundColor(.textMuted)
                        Text(formatPercent(realizedAPY)).font(.caption).foregroundColor(realizedAPY > 0 ? .mint : .white)
                    }
                } else {
                    VStack(alignment: .leading) {
                        Text("Size").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(fund.config.fund_size_usd ?? 0)).font(.caption).foregroundColor(.textPrimary)
                    }
                    VStack(alignment: .leading) {
                        Text("Value").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(value)).font(.caption).foregroundColor(.textPrimary)
                    }
                    VStack(alignment: .leading) {
                        Text("Realized").font(.caption2).foregroundColor(.textMuted)
                        Text(formatPercent(realizedAPY)).font(.caption).foregroundColor(realizedAPY > 0 ? .mint : .red)
                    }
                    VStack(alignment: .leading) {
                        Text("Liquid").font(.caption2).foregroundColor(.textMuted)
                        Text(formatPercent(liquidAPY)).font(.caption).foregroundColor(liquidAPY > 0 ? .mint : .red)
                    }
                }
            }

            HStack {
                Text("\(fund.entries.count) entries").font(.caption2).foregroundColor(.textMuted)
                Spacer()
                if let first = fund.entries.first, let last = fund.entries.last {
                    Text("\(first.date) \u{2192} \(last.date)").font(.caption2).foregroundColor(.textMuted)
                }
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        #if os(iOS)
        .padding(.horizontal)
        #endif
    }
}
