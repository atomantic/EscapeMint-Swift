import SwiftUI

struct PlatformsView: View {
    @State private var funds: [FundData] = []
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
        let grouped = Dictionary(grouping: funds, by: { $0.platform })
        return grouped.map { platform, platformFunds in
            PlatformInfo(
                name: platform,
                fundCount: platformFunds.count,
                activeFundCount: platformFunds.filter { $0.config.status != .closed }.count,
                totalValue: platformFunds.reduce(0) { $0 + getLatestValue($1.entries) },
                totalFundSize: platformFunds.reduce(0) { $0 + ($1.config.fund_size_usd ?? 0) }
            )
        }.sorted { $0.totalValue > $1.totalValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if platformInfos.isEmpty {
                    emptyState
                } else {
                    platformList
                }
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        .task { loadFunds() }
        .onReceive(NotificationCenter.default.publisher(for: .fundsDidChange)) { _ in
            loadFunds()
        }
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
            CreateFundView { loadFunds() }
        }
    }

    // MARK: - Header

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
            // Inline rename editor
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
            Button {
                NotificationCenter.default.post(name: .selectPlatform, object: info.name)
            } label: {
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

                    HStack(spacing: 0) {
                        statColumn(label: "Fund Size", value: formatCurrency(info.totalFundSize))
                        statColumn(label: "Current Value", value: formatCurrency(info.totalValue), color: .mint)
                        statColumn(label: "Funds", value: "\(info.fundCount)")
                        statColumn(label: "Active", value: "\(info.activeFundCount)")
                    }
                }
                .padding(14)
                .background(Color.bgCard)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .contextMenu {
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
            Text("Create a fund to add your first platform.")
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

    private func loadFunds() {
        Task {
            funds = await FundStore.shared.readAllFunds()
        }
    }

    private func attemptDelete(_ info: PlatformInfo) {
        if info.fundCount > 0 {
            platformToDelete = info.name
            showDeleteAlert = true
        }
    }

    private func renamePlatform(from oldName: String, to newName: String) {
        let cleanName = newName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleanName.isEmpty else { return }

        // Check if target name already exists
        if cleanName != oldName && platformInfos.contains(where: { $0.name == cleanName }) {
            renameErrorMessage = "A platform named '\(cleanName)' already exists."
            showRenameError = true
            return
        }

        Task {
            let platformFunds = funds.filter { $0.platform == oldName }
            for fund in platformFunds {
                let newId = "\(cleanName)-\(fund.ticker)"
                try? await FundStore.shared.writeFund(FundData(platform: cleanName, ticker: fund.ticker, config: fund.config, entries: fund.entries))
                if newId != fund.id {
                    try? await FundStore.shared.deleteFund(id: fund.id)
                }
            }
            editingPlatform = nil
            loadFunds()
            notifyFundsChanged()
        }
    }
}
