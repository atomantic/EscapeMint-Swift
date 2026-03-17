import SwiftUI

struct PlatformsView: View {
    private var store: FundDataStore { .shared }
    @State private var showDeleteAlert = false
    @State private var platformToDelete: String? = nil
    @State private var showCreateFund = false
    @State private var editingPlatform: String? = nil
    @State private var editName: String = ""
    @State private var showRenameError = false
    @State private var renameErrorMessage = ""

    struct PlatformInfo: Identifiable {
        var id: String { name }
        let name: String
        let fundCount: Int
        let activeFundCount: Int
        let totalValue: Double
        let totalFundSize: Double
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
                totalFundSize: active.reduce(0) { $0 + $1.metrics.fundSize }
            )
        }.sorted { $0.totalValue > $1.totalValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                #if os(macOS)
                header
                #endif
                if platformInfos.isEmpty {
                    emptyState
                } else {
                    platformList
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
        .alert("Cannot Delete Platform", isPresented: $showDeleteAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let name = platformToDelete {
                Text("\(name.capitalized) still has funds. Remove all funds from this platform before deleting it.")
            }
        }
        .alert("Rename Failed", isPresented: $showRenameError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameErrorMessage)
        }
        .sheet(isPresented: $showCreateFund) {
            CreateFundView { Task { await store.reload() } }
        }
    }

    // MARK: - Header (macOS only)

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Platforms")
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundColor(.textPrimary)
                Text("\(platformInfos.count) platform\(platformInfos.count == 1 ? "" : "s")")
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
    private var platformList: some View {
        ForEach(platformInfos) { info in
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
            HStack(spacing: 0) {
                statColumn(label: "Fund Size", value: formatCurrency(info.totalFundSize))
                statColumn(label: "Current Value", value: formatCurrency(info.totalValue), color: .mint)
                statColumn(label: "Funds", value: "\(info.fundCount)")
                statColumn(label: "Active", value: "\(info.activeFundCount)")
            }
            #else
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                statColumn(label: "Fund Size", value: formatCurrency(info.totalFundSize))
                statColumn(label: "Value", value: formatCurrency(info.totalValue), color: .mint)
                statColumn(label: "Funds", value: "\(info.fundCount)")
                statColumn(label: "Active", value: "\(info.activeFundCount)")
            }
            #endif
        }
        .padding(14)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

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
    }

    @ViewBuilder
    private func statColumn(label: String, value: String, color: Color = .textPrimary) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2).foregroundColor(.textMuted)
            Text(value)
                .font(.callout).fontWeight(.medium).foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
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
        if info.fundCount > 0 {
            platformToDelete = info.name
            showDeleteAlert = true
        }
    }

    private func renamePlatform(from oldName: String, to newName: String) {
        let cleanName = newName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleanName.isEmpty else { return }

        if cleanName != oldName && platformInfos.contains(where: { $0.name == cleanName }) {
            renameErrorMessage = "A platform named '\(cleanName)' already exists."
            showRenameError = true
            return
        }

        Task {
            let platformFunds = store.funds.filter { $0.platform == oldName }
            for fund in platformFunds {
                let renamedFund = FundData(platform: cleanName, ticker: fund.ticker, config: fund.config, entries: fund.entries)
                await store.addFund(renamedFund)
                if renamedFund.id != fund.id {
                    await store.deleteFund(id: fund.id)
                }
            }
            editingPlatform = nil
        }
    }
}
