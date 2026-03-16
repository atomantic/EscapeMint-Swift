import SwiftUI

@main
struct EscapeMintApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit EscapeMint") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        #endif
    }
}

struct ContentView: View {
    @State private var appearance = AppearanceManager.shared
    @AppStorage("escapemint-intro-completed") private var introCompleted = false
    @AppStorage("escapemint-show-intro-on-launch") private var showIntroOnLaunch = false
    @State private var showIntroGuide = false
    @State private var selectedTab: Int = {
        if CommandLine.arguments.contains("-startTab"),
           let idx = CommandLine.arguments.firstIndex(of: "-startTab"),
           idx + 1 < CommandLine.arguments.count,
           let tab = Int(CommandLine.arguments[idx + 1]) {
            return tab
        }
        return 0
    }()
    private var store: FundDataStore { .shared }

    var body: some View {
        Group {
            if !store.isConfigLoaded {
                loadingView
            } else {
                #if os(macOS)
                MacContentView()
                    .tint(.mint)
                #else
                tabContent
                .tint(.mint)
                .onReceive(NotificationCenter.default.publisher(for: .selectBacktest)) { _ in
                    selectedTab = 1
                }
                #endif
            }
        }
        .preferredColorScheme(appearance.mode.colorScheme)
        .sheet(isPresented: $showIntroGuide) {
            IntroGuideView(isPresented: $showIntroGuide)
        }
        .task {
            let isFirstTime = !introCompleted || showIntroOnLaunch
            // Start historical data loading immediately, boosted priority for first-time users
            ViewCache.shared.startLoading(prioritizeGuide: isFirstTime)
            if isFirstTime {
                ModeComparisonPreloader.shared.preload()
            }
            await store.loadIfNeeded()
        }
        .onAppear {
            if !introCompleted || showIntroOnLaunch {
                showIntroGuide = true
            }
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(.mint)
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg.ignoresSafeArea())
    }

    #if os(iOS)
    @ViewBuilder
    private var tabContent: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Dashboard", systemImage: "chart.bar.fill", value: 0) {
                    NavigationStack { DashboardView() }
                }
                Tab("Backtest", systemImage: "waveform.path.ecg", value: 1) {
                    NavigationStack { BacktestView() }
                }
                Tab("Audit Trail", systemImage: "list.clipboard.fill", value: 2) {
                    NavigationStack { AuditTrailView() }
                }
                Tab("Platforms", systemImage: "building.2.fill", value: 3) {
                    NavigationStack { PlatformsView() }
                }
                Tab("Settings", systemImage: "gear", value: 4) {
                    NavigationStack { SettingsView() }
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack { DashboardView() }
                    .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }
                    .tag(0)
                NavigationStack { BacktestView() }
                    .tabItem { Label("Backtest", systemImage: "waveform.path.ecg") }
                    .tag(1)
                NavigationStack { AuditTrailView() }
                    .tabItem { Label("Audit Trail", systemImage: "list.clipboard.fill") }
                    .tag(2)
                NavigationStack { PlatformsView() }
                    .tabItem { Label("Platforms", systemImage: "building.2.fill") }
                    .tag(3)
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(4)
            }
        }
    }
    #endif
}

#if os(macOS)
struct MacContentView: View {
    private var store: FundDataStore { .shared }
    @State private var selectedNav: NavItem? = .dashboard
    @State private var pendingAddEntryFundId: String?

    enum NavItem: Hashable {
        case dashboard
        case backtest
        case auditTrail
        case platforms
        case settings
        case fund(String)
        case platform(String)

        var id: String {
            switch self {
            case .dashboard: return "dashboard"
            case .backtest: return "backtest"
            case .auditTrail: return "auditTrail"
            case .platforms: return "platforms"
            case .settings: return "settings"
            case .fund(let id): return "fund-\(id)"
            case .platform(let name): return "platform-\(name)"
            }
        }
    }

    var activeFunds: [FundData] {
        store.funds.filter { $0.config.status != .closed }
            .sorted { getLatestValue($0.entries) > getLatestValue($1.entries) }
    }

    var closedFunds: [FundData] {
        store.funds.filter { $0.config.status == .closed }
    }

    var groupedActive: [(String, [FundData])] { groupByPlatform(activeFunds) }
    var groupedClosed: [(String, [FundData])] { groupByPlatform(closedFunds) }

    private func groupByPlatform(_ funds: [FundData]) -> [(String, [FundData])] {
        let grouped = Dictionary(grouping: funds, by: { $0.platform })
        return grouped.keys.sorted().compactMap { key in
            guard let funds = grouped[key] else { return nil }
            return (key, funds)
        }
    }

    @State private var collapsedPlatforms: Set<String> = []

    private func sidebarPlatformKey(_ platform: String, closed: Bool) -> String {
        "\(closed ? "closed" : "active"):\(platform)"
    }

    private func isSidebarCollapsed(_ platform: String, closed: Bool) -> Bool {
        collapsedPlatforms.contains(sidebarPlatformKey(platform, closed: closed))
    }

    private func toggleSidebarPlatform(_ platform: String, closed: Bool) {
        let key = sidebarPlatformKey(platform, closed: closed)
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedPlatforms.contains(key) {
                collapsedPlatforms.remove(key)
            } else {
                collapsedPlatforms.insert(key)
            }
        }
        saveSidebarCollapsedState()
    }

    private func saveSidebarCollapsedState() {
        UserDefaults.standard.set(Array(collapsedPlatforms), forKey: "escapemint-sidebar-collapsed")
    }

    private func loadSidebarCollapsedState() {
        if let saved = UserDefaults.standard.stringArray(forKey: "escapemint-sidebar-collapsed") {
            collapsedPlatforms = Set(saved)
        } else {
            for (platform, _) in groupedClosed {
                collapsedPlatforms.insert(sidebarPlatformKey(platform, closed: true))
            }
            saveSidebarCollapsedState()
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectFund)) { note in
            if let id = note.object as? String {
                selectedNav = .fund(id)
                // Auto-expand platform if collapsed
                if let fund = store.funds.first(where: { $0.id == id }) {
                    let closed = fund.config.status == .closed
                    let key = sidebarPlatformKey(fund.platform, closed: closed)
                    if collapsedPlatforms.contains(key) {
                        withAnimation(.easeInOut(duration: 0.2)) { _ = collapsedPlatforms.remove(key) }
                        saveSidebarCollapsedState()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddEntry)) { note in
            if let id = note.object as? String {
                pendingAddEntryFundId = id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectDashboard)) { _ in
            selectedNav = .dashboard
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPlatform)) { note in
            if let name = note.object as? String {
                selectedNav = .platform(name)
            }
        }
        .onChange(of: selectedNav) { _, newNav in
            // Clear stale pending add-entry if user navigated elsewhere
            guard let pending = pendingAddEntryFundId else { return }
            if case .fund(let id) = newNav, id == pending { return }
            pendingAddEntryFundId = nil
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedNav) {
            // Logo + name
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .foregroundColor(.mint)
                    .font(.title2)
                Text("EscapeMint")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.textPrimary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .padding(.vertical, 4)

            // Navigation
            Section("Navigation") {
                HStack {
                    Label("Dashboard", systemImage: "chart.bar.fill")
                    if store.actionableFunds.count > 0 {
                        Spacer()
                        Text("\(store.actionableFunds.count)")
                            .font(.caption2).fontWeight(.bold).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red).cornerRadius(8)
                    }
                }
                .tag(NavItem.dashboard)

                Label("Backtest", systemImage: "waveform.path.ecg")
                    .tag(NavItem.backtest)
                    .accessibilityIdentifier("nav-backtest")
                Label("Audit Trail", systemImage: "list.clipboard.fill")
                    .tag(NavItem.auditTrail)
                    .accessibilityIdentifier("nav-audit-trail")
                Label("Platforms", systemImage: "building.2.fill")
                    .tag(NavItem.platforms)
                    .accessibilityIdentifier("nav-platforms")
            }

            // Active funds grouped by platform
            Section("Active Funds") {
                ForEach(groupedActive, id: \.0) { platform, platformFunds in
                    // Platform header — chevron collapses, name navigates to platform
                    HStack {
                        Button { toggleSidebarPlatform(platform, closed: false) } label: {
                            Image(systemName: isSidebarCollapsed(platform, closed: false) ? "chevron.right" : "chevron.down")
                                .font(.caption2).foregroundColor(.textMuted)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)

                        HStack {
                            Image(systemName: "building.2")
                                .font(.caption).foregroundColor(.textMuted)
                            Text(platform.capitalized)
                                .font(.callout).fontWeight(.medium)
                                .foregroundColor(selectedNav == .platform(platform) ? .mint : .textPrimary)
                            Spacer()
                            Text("\(platformFunds.count)")
                                .font(.caption2)
                                .foregroundColor(.textMuted)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedNav = .platform(platform) }
                    }

                    // Individual funds (collapsible)
                    if !isSidebarCollapsed(platform, closed: false) {
                        ForEach(platformFunds) { fund in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.forCategory(fund.config.category))
                                    .frame(width: 6, height: 6)
                                Text(fund.ticker.uppercased())
                                    .font(.callout)
                                Spacer()
                                if let rec = store.summaryMap[fund.id]?.recommendation {
                                    let isHold = rec.action == .HOLD
                                    Text(rec.action.rawValue)
                                        .font(.caption2).fontWeight(.semibold)
                                        .foregroundColor(isHold ? .textMuted : .white)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(rec.action == .BUY ? Color.mintDark : rec.action == .SELL ? Color.red : Color.bgInput)
                                        .cornerRadius(3)
                                }
                            }
                            .padding(.leading, 12)
                            .tag(NavItem.fund(fund.id))
                        }
                    }
                }
            }

            if !closedFunds.isEmpty {
                Section("Closed Funds") {
                    ForEach(groupedClosed, id: \.0) { platform, platformFunds in
                        HStack {
                            Button { toggleSidebarPlatform(platform, closed: true) } label: {
                                Image(systemName: isSidebarCollapsed(platform, closed: true) ? "chevron.right" : "chevron.down")
                                    .font(.caption2).foregroundColor(.textMuted)
                                    .frame(width: 12)
                            }
                            .buttonStyle(.plain)

                            HStack {
                                Image(systemName: "building.2")
                                    .font(.caption).foregroundColor(.textMuted)
                                Text(platform.capitalized)
                                    .font(.callout).fontWeight(.medium)
                                    .foregroundColor(selectedNav == .platform(platform) ? .mint : .textMuted)
                                Spacer()
                                Text("\(platformFunds.count)")
                                    .font(.caption2)
                                    .foregroundColor(.textMuted)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedNav = .platform(platform) }
                        }

                        if !isSidebarCollapsed(platform, closed: true) {
                            ForEach(platformFunds) { fund in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.forCategory(fund.config.category))
                                        .frame(width: 6, height: 6)
                                    Text(fund.ticker.uppercased())
                                        .font(.callout)
                                        .foregroundColor(.textMuted)
                                }
                                .padding(.leading, 12)
                                .tag(NavItem.fund(fund.id))
                            }
                        }
                    }
                }
            }

            // Bottom section
            Section {
                Label("Settings", systemImage: "gear")
                    .tag(NavItem.settings)
            }

            // Version
            HStack {
                Spacer()
                Text("v1.0.0")
                    .font(.caption2)
                    .foregroundColor(.textMuted)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.bg)
        .toolbar(.hidden, for: .automatic)
        .onAppear { loadSidebarCollapsedState() }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selectedNav {
            case .dashboard, .none:
                DashboardView()
            case .backtest:
                BacktestView()
            case .auditTrail:
                AuditTrailView()
            case .platforms:
                PlatformsView()
            case .settings:
                SettingsView()
            case .fund(let id):
                FundDetailView(fundId: id, autoShowAddEntry: pendingAddEntryFundId == id)
                    .id(id)
                    .onAppear { pendingAddEntryFundId = nil }
            case .platform(let name):
                PlatformDetailView(platform: name)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
    }
}
#endif
