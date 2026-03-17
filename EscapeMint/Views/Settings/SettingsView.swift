import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearance = AppearanceManager.shared
    @State private var fundCount = 0
    @State private var dataSize = "..."
    @State private var storageLocation = "..."
    @State private var showImport = false
    @State private var statusMessage = ""
    @State private var showStatus = false
    @State private var showClearConfirm = false
    @State private var showLoadTestConfirm = false
    @State private var showRemoveTestConfirm = false
    @State private var testFundCount = 0
    @AppStorage("escapemint-show-intro-on-launch") var showIntroOnLaunch = false
    @State private var showIntroGuide = false

    var body: some View {
        settingsContent
    }

    @ViewBuilder
    private var settingsContent: some View {
        List {
                Section("Intro Guide") {
                    Toggle("Show intro on launch", isOn: $showIntroOnLaunch)
                    Button("Show Intro Guide") {
                        showIntroGuide = true
                    }
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
                    Button("Load Test Data") { showLoadTestConfirm = true }
                    if testFundCount > 0 {
                        Button("Remove Test Data", role: .destructive) { showRemoveTestConfirm = true }
                    }
                    Button("Clear All Data", role: .destructive) { showClearConfirm = true }
                }

                Section("About") {
                    LabeledContent("App", value: "EscapeMint")
                    LabeledContent("Version", value: "1.0.0")
                }

                if let privacyURL = URL(string: "https://github.com/atomantic/EscapeMint/blob/main/docs/PRIVACY.md"),
                   let termsURL = URL(string: "https://github.com/atomantic/EscapeMint/blob/main/docs/TERMS.md") {
                    Section("Legal") {
                        Link("Privacy Policy", destination: privacyURL)
                        Link("Terms of Use", destination: termsURL)
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.3), value: showStatus)
            .sheet(isPresented: $showIntroGuide) {
                IntroGuideView(isPresented: $showIntroGuide)
            }
            .alert("Clear All Data?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { clearDataWithBackup() }
            } message: {
                Text("A backup will be saved automatically before clearing. To restore, you'll need to re-import the backup file.")
            }
            .alert("Load Test Data", isPresented: $showLoadTestConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Load Test Data") { loadTestData() }
            } message: {
                Text("This will create 5 demo funds simulating DCA investing over 5 years:\n\n\u{2022} coinbasetest-btc (Bitcoin)\n\u{2022} robinhoodtest-tqqq (3x Nasdaq ETF)\n\u{2022} robinhoodtest-spxl (3x S&P 500 ETF)\n\u{2022} Plus cash funds for each platform\(testFundCount > 0 ? "\n\nExisting test funds will be replaced." : "")")
            }
            .alert("Remove Test Data?", isPresented: $showRemoveTestConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { removeTestData() }
            } message: {
                Text("This will delete all \(testFundCount) test \(testFundCount == 1 ? "fund" : "funds") (coinbasetest, robinhoodtest platforms). Your real funds will not be affected.")
            }
    }

    @State private var toastTask: Task<Void, Never>?

    private func showToast(_ message: String) {
        statusMessage = message
        showStatus = true
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            showStatus = false
        }
    }

    private func refreshStats() async {
        let stats = await FundStore.shared.dataStats()
        fundCount = stats.fundCount
        dataSize = stats.formattedSize
        storageLocation = FundStore.shared.isICloud ? "iCloud Drive" : "Local"
        testFundCount = await FundStore.shared.testFundCount()
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
                showToast("Import failed. Please check the file format.")
            }
            await refreshStats()
            await FundDataStore.shared.reload()
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
                showToast("Export failed. Please check folder permissions.")
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
                showToast("Import failed. Please check the folder contents.")
            }
            await refreshStats()
            await FundDataStore.shared.reload()
        }
    }

    private func loadTestData() {
        Task {
            do {
                let count = try await FundStore.shared.loadTestData()
                await FundDataStore.shared.reload()
                await refreshStats()
                showToast("Created \(count) test funds with simulated DCA history")
            } catch {
                showToast("Failed to load test data")
            }
        }
    }

    private func removeTestData() {
        Task {
            do {
                let count = try await FundStore.shared.deleteTestFunds()
                await FundDataStore.shared.reload()
                await refreshStats()
                showToast("Deleted \(count) test fund(s)")
            } catch {
                showToast("Failed to remove test data")
            }
        }
    }

    private func clearDataWithBackup() {
        Task {
            let stats = await FundStore.shared.dataStats()
            if stats.fundCount > 0 {
                do {
                    let backupURL = try await FundStore.shared.exportToBackupJSON()
                    // Move backup to Documents for persistence
                    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                        showToast("Could not access Documents directory")
                        return
                    }
                    let dest = docs.appendingPathComponent(backupURL.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: backupURL, to: dest)
                    try await FundStore.shared.deleteAllFunds()
                    await refreshStats()
                    await FundDataStore.shared.reload()
                    showToast("Backed up \(stats.fundCount) fund(s), then cleared")
                } catch {
                    showToast("Backup failed. Data was not cleared.")
                }
            } else {
                do { try await FundStore.shared.deleteAllFunds() } catch { showToast("Failed to clear data") }
                await FundDataStore.shared.reload()
                await refreshStats()
                showToast("All data cleared")
            }
        }
    }
}
