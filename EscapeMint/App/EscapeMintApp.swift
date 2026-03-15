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
    private var store = FundDataStore.shared

    var body: some View {
        Group {
            if !store.isLoaded {
                loadingView
            } else {
                #if os(macOS)
                MacContentView()
                    .tint(.mint)
                #else
                TabView {
                    NavigationStack {
                        DashboardView()
                    }
                    .tabItem {
                        Label("Dashboard", systemImage: "chart.bar.fill")
                    }
                    NavigationStack {
                        BacktestView()
                    }
                    .tabItem {
                        Label("Backtest", systemImage: "waveform.path.ecg")
                    }
                    NavigationStack {
                        AuditTrailView()
                    }
                    .tabItem {
                        Label("Audit Trail", systemImage: "list.clipboard.fill")
                    }
                    NavigationStack {
                        PlatformsView()
                    }
                    .tabItem {
                        Label("Platforms", systemImage: "building.2.fill")
                    }
                    NavigationStack {
                        SettingsView()
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                }
                .tint(.mint)
                #endif
            }
        }
        .preferredColorScheme(appearance.mode.colorScheme)
        .sheet(isPresented: $showIntroGuide) {
            IntroGuideView(isPresented: $showIntroGuide)
        }
        .task {
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
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg.ignoresSafeArea())
    }
}

#if os(macOS)
struct MacContentView: View {
    private var store = FundDataStore.shared
    @State private var selectedNav: NavItem? = .dashboard

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
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
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
                    // Platform header — tappable to view platform detail
                    HStack {
                        Image(systemName: "building.2")
                            .font(.caption).foregroundColor(.textMuted)
                        Text(platform.capitalized)
                            .font(.callout).fontWeight(.medium)
                        Spacer()
                        Text("\(platformFunds.count)")
                            .font(.caption2)
                            .foregroundColor(.textMuted)
                    }
                    .tag(NavItem.platform(platform))

                    // Individual funds
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

            if !closedFunds.isEmpty {
                Section("Closed Funds") {
                    ForEach(groupedClosed, id: \.0) { platform, platformFunds in
                        HStack {
                            Image(systemName: "building.2")
                                .font(.caption).foregroundColor(.textMuted)
                            Text(platform.capitalized)
                                .font(.callout).fontWeight(.medium)
                                .foregroundColor(.textMuted)
                            Spacer()
                            Text("\(platformFunds.count)")
                                .font(.caption2)
                                .foregroundColor(.textMuted)
                        }
                        .tag(NavItem.platform(platform))

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
                FundDetailView(fundId: id)
            case .platform(let name):
                PlatformDetailView(platform: name)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
    }
}
#endif
