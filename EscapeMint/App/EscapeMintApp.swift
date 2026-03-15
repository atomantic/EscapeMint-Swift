import SwiftUI

@main
struct EscapeMintApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}

struct ContentView: View {
    @State private var appearance = AppearanceManager.shared

    var body: some View {
        Group {
            #if os(macOS)
            MacContentView()
                .tint(.mint)
            #else
            TabView {
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "chart.bar.fill")
                    }
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .tint(.mint)
            #endif
        }
        .preferredColorScheme(appearance.mode.colorScheme)
    }
}

#if os(macOS)
struct MacContentView: View {
    @State private var funds: [FundData] = []
    @State private var summaries: [String: FundSummary] = [:]
    @State private var selectedNav: NavItem? = .dashboard

    enum NavItem: Hashable {
        case dashboard
        case settings
        case fund(String)
        case platform(String)

        var id: String {
            switch self {
            case .dashboard: return "dashboard"
            case .settings: return "settings"
            case .fund(let id): return "fund-\(id)"
            case .platform(let name): return "platform-\(name)"
            }
        }
    }

    var activeFunds: [FundData] {
        funds.filter { $0.config.status != .closed }
            .sorted { getLatestValue($0.entries) > getLatestValue($1.entries) }
    }

    var closedFunds: [FundData] {
        funds.filter { $0.config.status == .closed }
    }

    var groupedActive: [(String, [FundData])] {
        let grouped = Dictionary(grouping: activeFunds, by: { $0.platform })
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            await FundStore.shared.migrateToICloudIfNeeded()
            await loadFunds()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fundsDidChange)) { _ in
            Task { await loadFunds() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectFund)) { note in
            if let id = note.object as? String {
                selectedNav = .fund(id)
            }
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
                Label("Dashboard", systemImage: "chart.bar.fill")
                    .tag(NavItem.dashboard)
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
                            if let rec = summaries[fund.id]?.recommendation {
                                Text(rec.action.rawValue)
                                    .font(.caption2).fontWeight(.semibold)
                                    .foregroundColor(.white)
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
                    DisclosureGroup {
                        ForEach(closedFunds) { fund in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.forCategory(fund.config.category))
                                    .frame(width: 6, height: 6)
                                Text(fund.ticker.uppercased())
                                    .font(.callout)
                                    .foregroundColor(.textMuted)
                            }
                            .tag(NavItem.fund(fund.id))
                        }
                    } label: {
                        Text("\(closedFunds.count) closed")
                            .font(.callout)
                            .foregroundColor(.textMuted)
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

    private func loadFunds() async {
        funds = await FundStore.shared.readAllFunds()
        var sums: [String: FundSummary] = [:]
        for fund in funds {
            sums[fund.id] = FundSummary(fund)
        }
        summaries = sums
    }
}
#endif
