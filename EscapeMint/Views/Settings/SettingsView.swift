import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var appearance = AppearanceManager.shared
    @State private var fundCount = 0
    @State private var dataSize = "..."
    @State private var storageLocation = "..."
    @State private var showImport = false
    @State private var statusMessage = ""
    @State private var showStatus = false

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Storage") {
                    LabeledContent("Location", value: storageLocation)
                    LabeledContent("Funds", value: "\(fundCount)")
                    LabeledContent("Data Size", value: dataSize)
                }

                Section("Import / Export") {
                    Button("Import from Backup (.json)") { pickAndImportJSON() }
                    Button("Import from Folder (TSV+JSON)") { pickAndImport() }
                    #if os(macOS)
                    Button("Export to Folder") { pickAndExport() }
                    #endif
                }

                Section("Actions") {
                    Button("Generate Test Data") { generateTestData() }
                    Button("Clear All Data", role: .destructive) { clearData() }
                }

                Section("About") {
                    LabeledContent("App", value: "EscapeMint")
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
            .task { await refreshStats() }
            .overlay(alignment: .bottom) {
                if showStatus {
                    Text(statusMessage)
                        .font(.callout).fontWeight(.medium)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.mint.cornerRadius(10))
                        .shadow(radius: 4)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showStatus)
        }
    }

    private func showToast(_ message: String) {
        statusMessage = message
        showStatus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            showStatus = false
        }
    }

    private func refreshStats() async {
        let stats = await FundStore.shared.dataStats()
        fundCount = stats.fundCount
        dataSize = stats.formattedSize
        storageLocation = await FundStore.shared.isICloud ? "iCloud Drive" : "Local"
    }

    private func pickAndImportJSON() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Select backup JSON file"
        panel.message = "Choose an EscapeMint backup file (escapemint-backup-*.json)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard let window = NSApp.keyWindow else {
            if panel.runModal() == .OK, let url = panel.url {
                importBackupJSON(from: url)
            }
            return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.importBackupJSON(from: url)
            }
        }
        #else
        // iOS: use file importer for JSON
        showImport = true
        #endif
    }

    private func importBackupJSON(from url: URL) {
        Task {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try await FundStore.shared.importFromBackupJSON(url)
                showToast("Restored \(count) fund(s) from backup")
            } catch {
                showToast("Import failed: \(error.localizedDescription)")
            }
            await refreshStats()
            notifyFundsChanged()
        }
    }

    private func pickAndImport() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Select funds directory"
        panel.message = "Choose the folder containing your .tsv and .json fund files (e.g. data/funds/)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        guard let window = NSApp.keyWindow else {
            // Fallback: run as standalone panel
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

    #if os(macOS)
    private func pickAndExport() {
        let panel = NSOpenPanel()
        panel.title = "Select export destination"
        panel.message = "Choose a folder to export your fund data to"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard let window = NSApp.keyWindow else {
            if panel.runModal() == .OK, let url = panel.url {
                exportFunds(to: url)
            }
            return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.exportFunds(to: url)
            }
        }
    }

    private func exportFunds(to url: URL) {
        Task {
            do {
                let count = try await FundStore.shared.exportToDirectory(url)
                showToast("Exported \(count) fund(s)")
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }
    #endif

    private func importFunds(from url: URL) {
        Task {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try await FundStore.shared.importFromDirectory(url)
                showToast("Imported \(count) fund(s)")
            } catch {
                showToast("Import failed: \(error.localizedDescription)")
            }
            await refreshStats()
            notifyFundsChanged()
        }
    }

    private func generateTestData() {
        Task {
            var stockConfig = fundTypeDefaults[.stock]!
            stockConfig.fund_type = .stock
            stockConfig.status = .active
            stockConfig.category = .volatility
            stockConfig.fund_size_usd = 5000
            stockConfig.target_apy = 0.50
            stockConfig.input_min_usd = 1000
            stockConfig.input_mid_usd = 1000
            stockConfig.input_max_usd = 2000

            let stockEntries: [FundEntry] = [
                FundEntry(date: "2025-01-06", value: 500, action: .BUY, amount: 500, shares: 7.14, price: 70.00),
                FundEntry(date: "2025-01-13", value: 520, action: .HOLD),
                FundEntry(date: "2025-01-20", value: 480, action: .BUY, amount: 150, shares: 2.21, price: 67.87),
                FundEntry(date: "2025-02-03", value: 710, action: .HOLD),
                FundEntry(date: "2025-02-10", value: 690, action: .BUY, amount: 100, shares: 1.40, price: 71.43),
                FundEntry(date: "2025-03-03", value: 850, action: .HOLD),
                FundEntry(date: "2025-03-10", value: 780, action: .BUY, amount: 150, shares: 2.08, price: 72.12),
                FundEntry(date: "2025-04-01", value: 920, action: .HOLD),
                FundEntry(date: "2025-04-07", value: 1050, action: .HOLD),
            ]

            try? await FundStore.shared.writeFund(FundData(platform: "demo", ticker: "tqqq", config: stockConfig, entries: stockEntries))

            var cashConfig = fundTypeDefaults[.cash]!
            cashConfig.fund_type = .cash
            cashConfig.status = .active
            cashConfig.category = .liquidity
            cashConfig.fund_size_usd = 10000
            cashConfig.cash_apy = 0.04

            let cashEntries: [FundEntry] = [
                FundEntry(date: "2025-01-01", value: 5000, cash: 5000, action: .DEPOSIT, amount: 5000),
                FundEntry(date: "2025-02-01", value: 5200, cash: 5200, action: .DEPOSIT, amount: 200),
                FundEntry(date: "2025-03-01", value: 5400, cash: 5400, action: .DEPOSIT, amount: 200, cash_interest: 16.67),
            ]

            try? await FundStore.shared.writeFund(FundData(platform: "demo", ticker: "savings", config: cashConfig, entries: cashEntries))

            await refreshStats()
            notifyFundsChanged()
            showToast("Generated 2 test funds")
        }
    }

    private func clearData() {
        Task {
            try? await FundStore.shared.deleteAllFunds()
            await refreshStats()
            notifyFundsChanged()
            showToast("All data cleared")
        }
    }
}
