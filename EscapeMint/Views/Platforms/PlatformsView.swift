import SwiftUI

struct PlatformsView: View {
    private var store: FundDataStore { .shared }
    @State private var platformToDelete: PlatformInfo? = nil
    @State private var showCreateFund = false
    @State private var editingPlatform: String? = nil
    @State private var editName: String = ""
    @State private var showRenameError = false
    @State private var renameErrorMessage = ""
    @State private var isDeletingPlatform = false

    struct PlatformInfo: Identifiable {
        var id: String { name }
        let name: String
        let fundCount: Int
        let activeFundCount: Int
        let totalValue: Double
        let totalFundSize: Double
        let totalRealized: Double
        let totalUnrealized: Double
        let cashBalance: Double
    }

    var platformInfos: [PlatformInfo] {
        let grouped = Dictionary(grouping: store.summaries, by: { $0.fund.platform })
        return grouped.map { platform, summaries in
            let active = summaries.filter { $0.fund.config.status != .closed }
            return PlatformInfo(
                name: platform,
                fundCount: summaries.count,
                activeFundCount: active.count,
                totalValue: active.reduce(0) { $0 + $1.currentValue },
                totalFundSize: active.reduce(0) { $0 + $1.metrics.fundSize },
                totalRealized: summaries.reduce(0) { $0 + $1.effectiveRealized },
                totalUnrealized: summaries.reduce(0) { $0 + $1.unrealizedGains },
                // In-fund cash (see FundMetrics.cash) so shared platform cash is counted once
                cashBalance: active.reduce(0) { $0 + $1.metrics.cash }
            )
        }.sorted { $0.totalValue > $1.totalValue }
    }

    var body: some View {
        let infos = platformInfos
        return ScrollView {
            VStack(spacing: 16) {
                #if os(macOS)
                header(count: infos.count)
                #endif
                if infos.isEmpty {
                    emptyState
                } else {
                    platformList(infos)
                }
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Platforms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showCreateFund = true } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.mint)
            }
        }
        #endif
        .alert(
            "Delete Platform?",
            isPresented: Binding(
                get: { platformToDelete != nil },
                set: { if !$0 { platformToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                platformToDelete = nil
            }
            if let info = platformToDelete {
                Button("Delete \(info.fundCount) Fund\(info.fundCount == 1 ? "" : "s")", role: .destructive) {
                    deletePlatform(info)
                }
            }
        } message: {
            if let info = platformToDelete {
                Text("This permanently deletes every fund and entry on \(info.name.capitalized), including old synced files that can reappear from iCloud.")
            }
        }
        .alert("Rename Failed", isPresented: $showRenameError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameErrorMessage)
        }
        .sheet(isPresented: $showCreateFund) {
            CreateFundView {}
        }
    }

    // MARK: - Header (macOS only)

    @ViewBuilder
    private func header(count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Platforms")
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundColor(.textPrimary)
                Text("\(count) platform\(count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundColor(.textSecondary)
            }
            Spacer()
            Button { showCreateFund = true } label: {
                Label("Add Fund", systemImage: "plus.circle.fill")
                    .font(.callout).fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent).tint(.mint)
        }
    }

    // MARK: - Platform List

    @ViewBuilder
    private func platformList(_ infos: [PlatformInfo]) -> some View {
        ForEach(infos) { info in
            platformCard(info)
        }
    }

    // MARK: - Platform Card

    @ViewBuilder
    private func platformCard(_ info: PlatformInfo) -> some View {
        if editingPlatform == info.name {
            VStack(spacing: 8) {
                HStack {
                    TextField("Platform name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                    Button("Save") { renamePlatform(from: info.name, to: editName) }
                        .buttonStyle(.borderedProminent).tint(.mint)
                        .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { editingPlatform = nil }
                        .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(Color.bgCard)
            .cornerRadius(12)
        } else {
            #if os(macOS)
            Button {
                NotificationCenter.default.post(name: .selectPlatform, object: info.name)
            } label: {
                platformCardContent(info)
            }
            .buttonStyle(.plain)
            .contextMenu {
                platformContextMenu(info)
            }
            #else
            NavigationLink(destination: PlatformDetailView(platform: info.name)) {
                platformCardContent(info)
            }
            .buttonStyle(.plain)
            .contextMenu {
                platformContextMenu(info)
            }
            #endif
        }
    }

    @ViewBuilder
    private func platformCardContent(_ info: PlatformInfo) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name.capitalized)
                        .font(.headline).fontWeight(.semibold)
                        .foregroundColor(.textPrimary)
                    Text("\(info.activeFundCount) active / \(info.fundCount) total fund\(info.fundCount == 1 ? "" : "s")")
                        .font(.caption).foregroundColor(.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.textMuted)
                    .padding(.top, 4)
            }

            Divider()
                .background(Color.bgInput)
                .padding(.vertical, 10)

            #if os(macOS)
            LazyVGrid(columns: platformCardMetricColumns, alignment: .leading, spacing: 14) {
                platformMetric("Fund Size", formatCurrency(info.totalFundSize))
                platformMetric("Current Value", formatCurrency(info.totalValue), color: .mint)
                platformMetric("Realized Gain", formatCurrency(info.totalRealized), color: info.totalRealized >= 0 ? .mint : .red)
                platformMetric("Unrealized Gain", formatCurrency(info.totalUnrealized), color: info.totalUnrealized >= 0 ? .mint : .red)
                platformMetric("Cash", formatCurrency(info.cashBalance))
            }
            #else
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                StatBox(label: "Fund Size", value: formatCurrency(info.totalFundSize), showCard: false)
                StatBox(label: "Value", value: formatCurrency(info.totalValue), color: .mint, showCard: false)
            }
            #endif
        }
        .padding(14)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    #if os(macOS)
    private var platformCardMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .leading)]
    }

    private func platformMetric(_ label: String, _ value: String, color: Color = .textPrimary) -> some View {
        StatBox(label: label, value: value, color: color, showCard: false)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    @ViewBuilder
    private func platformContextMenu(_ info: PlatformInfo) -> some View {
        Button {
            editName = info.name
            editingPlatform = info.name
        } label: {
            Label("Rename Platform", systemImage: "pencil")
        }
        Button(role: .destructive) {
            attemptDelete(info)
        } label: {
            Label("Delete Platform", systemImage: "trash")
        }
        .disabled(isDeletingPlatform)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.2")
                .font(.largeTitle).foregroundColor(.mint)
            Text("No platforms yet")
                .font(.title2).fontWeight(.semibold).foregroundColor(.textPrimary)
            Text("Platforms are created automatically when you add a fund. Head to the Dashboard to get started.")
                .font(.subheadline).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            Button { showCreateFund = true } label: {
                Label("Add Fund", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent).tint(.mint)
        }
        .padding(.top, 60)
    }

    // MARK: - Actions


    private func attemptDelete(_ info: PlatformInfo) {
        platformToDelete = info
    }

    private func deletePlatform(_ info: PlatformInfo) {
        platformToDelete = nil
        isDeletingPlatform = true
        Task {
            await store.deletePlatform(named: info.name)
            editingPlatform = nil
            isDeletingPlatform = false
        }
    }

    private func renamePlatform(from oldName: String, to newName: String) {
        let cleanName = newName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleanName.isEmpty else { return }

        guard cleanName != oldName else {
            editingPlatform = nil
            return
        }

        if platformInfos.contains(where: { $0.name == cleanName }) {
            renameErrorMessage = "A platform named '\(cleanName)' already exists."
            showRenameError = true
            return
        }

        Task {
            let edits = store.funds
                .filter { $0.platform == oldName }
                .map { fund in
                    (oldId: fund.id,
                     newFund: FundData(platform: cleanName, ticker: fund.ticker, config: fund.config, entries: fund.entries))
                }
            await store.renameFunds(edits)
            editingPlatform = nil
        }
    }
}
