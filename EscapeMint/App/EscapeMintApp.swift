import SwiftUI
import CoreSpotlight
import UserNotifications

#if os(macOS)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var reopenWindow: (() -> Void)?

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DispatchQueue.main.async {
                Self.showOrCreateMainWindow()
            }
        }
        return true
    }

    static func showOrCreateMainWindow() {
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        reopenWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

@main
struct EscapeMintApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // Set notification delegate before any pending responses are delivered
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        // Handle -loadTestData synchronously before any views load
        if CommandLine.arguments.contains("-loadTestData") {
            UserDefaults.standard.set(true, forKey: AppStorageKeys.introCompleted)
            UserDefaults.standard.set(false, forKey: AppStorageKeys.showIntroOnLaunch)
            FundStore.shared.loadTestDataSynchronously()
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit EscapeMint") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                NewFundCommand()
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    AppDelegate.showOrCreateMainWindow()
                    NotificationCenter.default.post(name: .fundsDidChange, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                ShowMainWindowCommand()
            }
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                AuthManager.shared.lock()
            }
        }
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

struct ContentView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var appearance = AppearanceManager.shared
    @State private var auth = AuthManager.shared
    @AppStorage(AppStorageKeys.introCompleted) private var introCompleted = false
    @AppStorage(AppStorageKeys.showIntroOnLaunch) private var showIntroOnLaunch = false
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
            if auth.isEnabled && !auth.isUnlocked {
                LockScreenView()
            } else if !store.isConfigLoaded {
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
        .privacySensitive()
        .toast(
            isPresented: Binding(
                get: { store.lastDiskWriteError != nil },
                set: { if !$0 { store.lastDiskWriteError = nil } }
            ),
            message: store.lastDiskWriteError ?? ""
        )
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let fundId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            NotificationCenter.default.post(name: .selectFund, object: fundId)
        }
        .sheet(isPresented: $showIntroGuide) {
            IntroGuideView(isPresented: $showIntroGuide)
        }
        .task {
            // -loadTestData is handled in EscapeMintApp.init() before views load
            let isFirstTime = !introCompleted || showIntroOnLaunch
            // Start historical data loading immediately, boosted priority for first-time users
            ViewCache.shared.startLoading(prioritizeGuide: isFirstTime)
            if isFirstTime {
                ModeComparisonPreloader.shared.preload()
            }
            await store.loadIfNeeded()
            ICloudSyncMonitor.shared.startMonitoring()
            #if os(iOS)
            applyLaunchNavigationArguments()
            #endif
            // -selectFund <id>: auto-navigate to fund detail after load
            if let idx = CommandLine.arguments.firstIndex(of: "-selectFund"),
               idx + 1 < CommandLine.arguments.count {
                let fundId = CommandLine.arguments[idx + 1]
                try? await Task.sleep(for: .milliseconds(500))
                NotificationCenter.default.post(name: .selectFund, object: fundId)
            }
        }
        .onAppear {
            #if os(macOS)
            AppDelegate.reopenWindow = { [openWindow] in openWindow(id: "main") }
            #endif
            if CommandLine.arguments.contains("-loadTestData") { return }
            if !introCompleted || showIntroOnLaunch {
                showIntroGuide = true
            }
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        EscapeMintLoadingView(
            message: store.loadingPhase.message,
            progress: nil,
            loadedCount: store.loadedFundCount,
            totalCount: store.funds.count
        )
    }

    #if os(iOS)
    @State private var dashboardPath = NavigationPath()

    private func launchValue(after flag: String, environmentKey: String) -> String? {
        if let idx = CommandLine.arguments.firstIndex(of: flag),
           idx + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[idx + 1]
        }
        return ProcessInfo.processInfo.environment[environmentKey]
    }

    private func applyLaunchNavigationArguments() {
        if let tabValue = launchValue(after: "-startTab", environmentKey: "ESCAPEMINT_START_TAB"),
           let tab = Int(tabValue) {
            selectedTab = tab
        }

        if let fundId = launchValue(after: "-selectFund", environmentKey: "ESCAPEMINT_SELECT_FUND") {
            selectedTab = 0
            dashboardPath = NavigationPath()
            dashboardPath.append(fundId)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Dashboard", systemImage: "chart.bar.fill", value: 0) {
                    NavigationStack(path: $dashboardPath) {
                        DashboardView()
                            .navigationDestination(for: String.self) { fundId in
                                FundDetailView(fundId: fundId)
                            }
                    }
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
            .onReceive(NotificationCenter.default.publisher(for: .selectFund)) { note in
                if let id = note.object as? String {
                    selectedTab = 0
                    dashboardPath = NavigationPath()
                    dashboardPath.append(id)
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack(path: $dashboardPath) {
                    DashboardView()
                        .navigationDestination(for: String.self) { fundId in
                            FundDetailView(fundId: fundId)
                        }
                }
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
            .onReceive(NotificationCenter.default.publisher(for: .selectFund)) { note in
                if let id = note.object as? String {
                    selectedTab = 0
                    dashboardPath = NavigationPath()
                    dashboardPath.append(id)
                }
            }
        }
    }
    #endif
}

#if os(macOS)
struct NewFundCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Fund") {
            ensureMainWindow()
            // Wait for the main window (and its notification observer) to exist
            // before posting, instead of guessing with a fixed delay. Poll on the
            // main actor with a short cap so the command still fires even if the
            // window never reports ready.
            Task { @MainActor in
                for _ in 0..<30 { // up to ~1.5s (30 * 50ms)
                    if NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                NotificationCenter.default.postShowCreateFund()
            }
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private func ensureMainWindow() {
        if NSApp.windows.contains(where: { $0.canBecomeMain }) {
            AppDelegate.showOrCreateMainWindow()
        } else {
            openWindow(id: "main")
        }
    }
}

struct ShowMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Main Window") {
            AppDelegate.showOrCreateMainWindow()
        }
        .keyboardShortcut("0", modifiers: .command)
        .onAppear {
            AppDelegate.reopenWindow = { [openWindow] in openWindow(id: "main") }
        }
    }
}
#endif

#if os(macOS)
struct MacContentView: View {
    private var store: FundDataStore { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedNav: NavItem? = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
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

    // Read from the store's pre-computed summaries rather than recomputing per
    // render. `FundSummary` already carries the fund alongside its computed
    // state/metrics, so the sidebar reuses that work instead of re-deriving it.
    var activeFunds: [FundData] {
        store.summaries.filter { $0.fund.config.status != .closed }
            .sorted { getLatestValue($0.fund.entries) > getLatestValue($1.fund.entries) }
            .map { $0.fund }
    }

    var closedFunds: [FundData] {
        store.summaries.filter { $0.fund.config.status == .closed }
            .map { $0.fund }
    }

    var groupedActive: [(String, [FundData])] { groupByPlatform(activeFunds) }
    var groupedClosed: [(String, [FundData])] { groupByPlatform(closedFunds) }

    private func groupByPlatform(_ funds: [FundData]) -> [(String, [FundData])] {
        let grouped = Dictionary(grouping: funds, by: { $0.platform })
        return grouped.keys.sorted().compactMap { key in
            guard let funds = grouped[key] else { return nil }
            return (key, funds.sorted { $0.ticker.lowercased() < $1.ticker.lowercased() })
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            if collapsedPlatforms.contains(key) {
                collapsedPlatforms.remove(key)
            } else {
                collapsedPlatforms.insert(key)
            }
        }
        saveSidebarCollapsedState()
    }

    private func saveSidebarCollapsedState() {
        UserDefaults.standard.set(Array(collapsedPlatforms), forKey: AppStorageKeys.sidebarCollapsed)
    }

    private func loadSidebarCollapsedState() {
        if let saved = UserDefaults.standard.stringArray(forKey: AppStorageKeys.sidebarCollapsed) {
            collapsedPlatforms = Set(saved)
        } else {
            for (platform, _) in groupedClosed {
                collapsedPlatforms.insert(sidebarPlatformKey(platform, closed: true))
            }
            saveSidebarCollapsedState()
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .selectFund)) { note in
            if let id = note.object as? String {
                selectedNav = .fund(id)
                // Auto-expand platform if collapsed
                if let fund = store.funds.first(where: { $0.id == id }) {
                    let closed = fund.config.status == .closed
                    let key = sidebarPlatformKey(fund.platform, closed: closed)
                    if collapsedPlatforms.contains(key) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { _ = collapsedPlatforms.remove(key) }
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
        .onReceive(NotificationCenter.default.publisher(for: .selectBacktest)) { _ in
            selectedNav = .backtest
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
            // Logo + name + sync
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .foregroundColor(.mint)
                    .font(.title2)
                Text("EscapeMint")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.textPrimary)
                Spacer()
                if FundStore.shared.isICloud {
                    Button {
                        Task { await ICloudSyncMonitor.shared.syncNow() }
                    } label: {
                        if ICloudSyncMonitor.shared.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                                .foregroundColor(.textMuted)
                                .font(.callout)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sync with iCloud")
                }
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
                    // Platform header — tap navigates AND toggles collapse
                    HStack {
                        Image(systemName: isSidebarCollapsed(platform, closed: false) ? "chevron.right" : "chevron.down")
                            .font(.caption2).foregroundColor(.textMuted)
                            .frame(width: 12)
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
                    .onTapGesture {
                        selectedNav = .platform(platform)
                        toggleSidebarPlatform(platform, closed: false)
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
                                if let summary = store.summaryMap[fund.id],
                                   summary.isDueForAction,
                                   let rec = summary.recommendation {
                                    let isHold = rec.action == .HOLD
                                    Text(rec.action.rawValue)
                                        .font(.caption2).fontWeight(.semibold)
                                        .foregroundColor(isHold ? .textMuted : .white)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.backgroundForAction(rec.action))
                                        .cornerRadius(3)
                                }
                            }
                            .padding(.leading, 20)
                            .padding(.vertical, 1)
                            .tag(NavItem.fund(fund.id))
                        }
                        .listRowBackground(Color.white.opacity(0.03))
                    }
                }
            }

            if !closedFunds.isEmpty {
                Section("Closed Funds") {
                    ForEach(groupedClosed, id: \.0) { platform, platformFunds in
                        HStack {
                            Image(systemName: isSidebarCollapsed(platform, closed: true) ? "chevron.right" : "chevron.down")
                                .font(.caption2).foregroundColor(.textMuted)
                                .frame(width: 12)
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
                        .onTapGesture {
                            selectedNav = .platform(platform)
                            toggleSidebarPlatform(platform, closed: true)
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
                                .padding(.leading, 20)
                                .padding(.vertical, 1)
                                .tag(NavItem.fund(fund.id))
                            }
                            .listRowBackground(Color.white.opacity(0.03))
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
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
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
