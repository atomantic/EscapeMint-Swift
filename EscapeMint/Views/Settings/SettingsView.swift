import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var appearance = AppearanceManager.shared
    @State private var fundCount = 0
    @State private var dataSize = "..."
    @State private var storageLocation = "..."
    @State private var showImportJSON = false
    @State private var statusMessage = ""
    @State private var showStatus = false
    @State private var showClearConfirm = false
    @State private var showLoadTestConfirm = false
    @State private var showRemoveTestConfirm = false
    @State private var testFundCount = 0
    @AppStorage(AppStorageKeys.showIntroOnLaunch) var showIntroOnLaunch = false
    @AppStorage(AppStorageKeys.advancedTools) var advancedToolsEnabled = false
    @State private var showIntroGuide = false
    @State private var backupFileURL: URL?
    @State private var showShareSheet = false
    @State private var auth = AuthManager.shared
    @State private var notifications = DCANotificationManager.shared

    var body: some View {
        settingsContent
    }

    @ViewBuilder
    private var settingsContent: some View {
        List {
                Section("Security") {
                    if auth.biometryAvailable {
                        Toggle("Require \(auth.biometryName)", isOn: Binding(
                            get: { auth.isEnabled },
                            set: { auth.setEnabled($0) }
                        ))
                    } else {
                        LabeledContent("Biometric Auth", value: "Not Available")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("DCA Reminders", isOn: Binding(
                        get: { notifications.isEnabled },
                        set: { enabled in
                            Task { await notifications.setEnabled(enabled) }
                        }
                    ))
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get notified when a fund is due for its next DCA action based on its interval setting.")
                }

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
                    if FundStore.shared.isICloud {
                        Button {
                            Task {
                                await ICloudSyncMonitor.shared.syncNow()
                                await refreshStats()
                                showToast("Synced from iCloud")
                            }
                        } label: {
                            HStack {
                                Label("Sync with iCloud", systemImage: "arrow.triangle.2.circlepath.icloud")
                                if ICloudSyncMonitor.shared.isSyncing {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(ICloudSyncMonitor.shared.isSyncing)
                    }
                }

                Section("Import / Export") {
                    Button("Import from Backup (.json)") { pickAndImportJSON() }
                    Button("Export Backup (.json)") { exportBackup() }
                }

                Section("Actions") {
                    Button("Load Test Data") { showLoadTestConfirm = true }
                    if testFundCount > 0 {
                        Button("Remove Test Data", role: .destructive) { showRemoveTestConfirm = true }
                    }
                    Button("Clear All Data", role: .destructive) { showClearConfirm = true }
                }

                Section {
                    Toggle("Enable Advanced/Beta Tools", isOn: $advancedToolsEnabled)
                } header: {
                    Text("Advanced / Beta")
                } footer: {
                    Text("Shows recalculate and interpolate tools in fund detail views. Data is automatically backed up before each operation.")
                }

                Section("About") {
                    LabeledContent("App", value: "EscapeMint")
                    LabeledContent("Version", value: {
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                        return "\(version) (\(build))"
                    }())
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
            .toast(isPresented: $showStatus, message: statusMessage)
            .sheet(isPresented: $showIntroGuide) {
                IntroGuideView(isPresented: $showIntroGuide)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = backupFileURL {
                    ShareSheetView(items: [url])
                }
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
            .fileImporter(isPresented: $showImportJSON, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    importBackupJSON(from: url)
                }
            }
    }

    private func showToast(_ message: String) {
        statusMessage = message
        showStatus = true
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
        showOpenPanel(
            title: "Select backup JSON file",
            message: "Choose an EscapeMint backup file (escapemint-backup-*.json)",
            canChooseFiles: true,
            canChooseDirectories: false,
            allowedContentTypes: [.json]
        ) { url in
            self.importBackupJSON(from: url)
        }
        #else
        showImportJSON = true
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

    private func exportBackup() {
        Task {
            do {
                let url = try await FundStore.shared.exportToBackupJSON()
                #if os(macOS)
                let panel = NSSavePanel()
                panel.title = "Save Backup"
                panel.nameFieldStringValue = url.lastPathComponent
                panel.allowedContentTypes = [.json]
                let response: NSApplication.ModalResponse
                if let window = NSApp.keyWindow {
                    response = await panel.beginSheetModal(for: window)
                } else {
                    response = panel.runModal()
                }
                if response == .OK, let dest = panel.url {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                    showToast("Backup saved")
                }
                #else
                backupFileURL = url
                showShareSheet = true
                #endif
            } catch {
                showToast("Export failed")
            }
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

#if os(iOS)
struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheetView: View {
    let items: [Any]

    var body: some View {
        Text("Use the save dialog to export.")
            .padding()
    }
}
#endif
