import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
private enum SettingsTab: String, CaseIterable, Hashable {
    case general = "General"
    case data = "Data"
    case about = "About"
}
#endif

private enum BackupImportMode {
    case merge
    case replace
}

struct SettingsView: View {
    @State private var appearance = AppearanceManager.shared
    @State private var fundCount = 0
    @State private var dataSize = "..."
    @State private var storageLocation = "..."
    @State private var showImportJSON = false
    @State private var pendingBackupImportURL: URL?
    @State private var statusMessage = ""
    @State private var showStatus = false
    @State private var showClearConfirm = false
    @State private var showLoadTestConfirm = false
    @State private var showRemoveTestConfirm = false
    @State private var testFundCount = 0
    @AppStorage(AppStorageKeys.showIntroOnLaunch) var showIntroOnLaunch = false
    @AppStorage(AppStorageKeys.advancedTools) var advancedToolsEnabled = false
    @AppStorage(AppStorageKeys.advancedEntryMode) var advancedEntryMode = false
    @State private var showIntroGuide = false
    @State private var backupShareItem: BackupShareItem?
    @State private var auth = AuthManager.shared
    @State private var notifications = DCANotificationManager.shared
    #if DEBUG
    @State private var showLoadingPreview = false
    #endif
    #if os(iOS)
    @State private var selectedTab: SettingsTab = .general
    #endif

    var body: some View {
        tabContainer
            .task { await refreshStats() }
            .toast(isPresented: $showStatus, message: statusMessage)
            .sheet(isPresented: $showIntroGuide) {
                IntroGuideView(isPresented: $showIntroGuide)
            }
            #if DEBUG
            .sheet(isPresented: $showLoadingPreview) {
                LoadingPreviewSheet()
            }
            #endif
            .sheet(item: $backupShareItem) { item in
                ShareSheetView(items: [item.url])
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
            .alert(
                "Restore Backup",
                isPresented: Binding(
                    get: { pendingBackupImportURL != nil },
                    set: { if !$0 { pendingBackupImportURL = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingBackupImportURL = nil
                }
                Button("Merge") {
                    confirmBackupImport(mode: .merge)
                }
                Button("Replace All", role: .destructive) {
                    confirmBackupImport(mode: .replace)
                }
            } message: {
                Text("Merge adds the backup into your current funds and overwrites matching fund IDs. Replace All clears current funds before restoring this backup.")
            }
            .fileImporter(isPresented: $showImportJSON, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    prepareBackupImport(from: url)
                }
            }
    }

    // MARK: - Tab Container

    #if os(macOS)
    private var col1: some View {
        Form { generalSections }
            .formStyle(.grouped)
    }

    private var col2: some View {
        Form { dataSections }
            .formStyle(.grouped)
    }

    private var col3: some View {
        Form { aboutSections }
            .formStyle(.grouped)
    }
    #endif

    @ViewBuilder
    private var tabContainer: some View {
        #if os(macOS)
        GeometryReader { geo in
            let w = geo.size.width
            ScrollView {
                Group {
                    if w >= 860 {
                        HStack(alignment: .top, spacing: 16) {
                            col1.frame(maxWidth: .infinity)
                            col2.frame(maxWidth: .infinity)
                            col3.frame(maxWidth: .infinity)
                        }
                    } else if w >= 540 {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) { col1; col3 }.frame(maxWidth: .infinity)
                            col2.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 16) { col1; col2; col3 }
                    }
                }
                .padding()
            }
        }
        #else
        VStack(spacing: 0) {
            Picker("Settings Tab", selection: Binding(
                get: { selectedTab },
                set: { newVal in withAnimation(.easeInOut(duration: 0.15)) { selectedTab = newVal } }
            )) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemGroupedBackground))

            List {
                switch selectedTab {
                case .general: generalSections
                case .data: dataSections
                case .about: aboutSections
                }
            }
            .listStyle(.insetGrouped)
            .animation(.easeInOut(duration: 0.15), value: selectedTab)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalSections: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }

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

        Section {
            Toggle("DCA Reminders", isOn: Binding(
                get: { notifications.isEnabled },
                set: { enabled in Task { await notifications.setEnabled(enabled) } }
            ))
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get notified when a fund is due for its next DCA action based on its interval setting.")
        }
        .toast(
            isPresented: Binding(
                get: { notifications.permissionDeniedMessage != nil },
                set: { if !$0 { notifications.permissionDeniedMessage = nil } }
            ),
            message: notifications.permissionDeniedMessage ?? ""
        )

        Section("Intro Guide") {
            Toggle("Show intro on launch", isOn: $showIntroOnLaunch)
            Button("Show Intro Guide") { showIntroGuide = true }
        }

        Section {
            Toggle("Advanced entry form", isOn: $advancedEntryMode)
        } header: {
            Text("Entry Mode")
        } footer: {
            Text("Off: guided wizard walks you through equity, recommendation, and action. On: single-screen form with every field exposed.")
        }
    }

    // MARK: - Data Tab

    @ViewBuilder
    private var dataSections: some View {
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
            Button {
                pickAndImportJSON()
            } label: {
                Label("Import from Backup (.json)", systemImage: "square.and.arrow.down")
            }
            Button {
                exportBackup()
            } label: {
                Label("Export Backup (.json)", systemImage: "square.and.arrow.up")
            }
        }

        Section("Actions") {
            Button {
                showLoadTestConfirm = true
            } label: {
                Label("Load Test Data", systemImage: "flask.fill")
            }
            if testFundCount > 0 {
                Button(role: .destructive) {
                    showRemoveTestConfirm = true
                } label: {
                    Label("Remove Test Data", systemImage: "trash")
                }
            }
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear All Data", systemImage: "xmark.bin.fill")
            }
        }
    }

    // MARK: - About Tab

    @ViewBuilder
    private var aboutSections: some View {
        Section {
            HStack(spacing: 14) {
                SettingsAppIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text("EscapeMint")
                        .font(.headline)
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                    Text("Version \(version) (\(build))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }

        Section {
            Toggle("Enable Advanced/Beta Tools", isOn: $advancedToolsEnabled)
        } header: {
            Text("Advanced / Beta")
        } footer: {
            Text("Shows recalculate and interpolate tools in fund detail views. Data is automatically backed up before each operation.")
        }

        #if DEBUG
        Section("Developer") {
            Button {
                showLoadingPreview = true
            } label: {
                Label("Preview Launch Loader", systemImage: "play.display")
            }
        }
        #endif

        if let privacyURL = URL(string: "https://github.com/atomantic/EscapeMint/blob/main/docs/PRIVACY.md"),
           let termsURL = URL(string: "https://github.com/atomantic/EscapeMint/blob/main/docs/TERMS.md") {
            Section("Legal") {
                Link("Privacy Policy", destination: privacyURL)
                Link("Terms of Use", destination: termsURL)
            }
        }
    }

    // MARK: - Actions

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
            self.prepareBackupImport(from: url)
        }
        #else
        showImportJSON = true
        #endif
    }

    private func prepareBackupImport(from url: URL) {
        pendingBackupImportURL = url
    }

    private func confirmBackupImport(mode: BackupImportMode) {
        guard let url = pendingBackupImportURL else { return }
        pendingBackupImportURL = nil
        importBackupJSON(from: url, mode: mode)
    }

    private func importBackupJSON(from url: URL, mode: BackupImportMode) {
        Task {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await FundStore.shared.backupJSONFundCount(url)
                if mode == .replace {
                    try await FundStore.shared.deleteAllFunds()
                }
                let count = try await FundStore.shared.importFromBackupJSON(url)
                ICloudSyncMonitor.shared.markLocalWrite()
                let action = mode == .replace ? "Replaced data with" : "Merged"
                showToast("\(action) \(count) fund(s) from backup")
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
                backupShareItem = BackupShareItem(url: url)
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
                    _ = try await FundStore.shared.exportToDocuments()
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

#if DEBUG
private struct LoadingPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            EscapeMintLoadingView(
                message: FundDataStore.LoadingPhase.loadingEntries.message,
                progress: 0.62,
                detail: "Previewing launch animation",
                loadedCount: 0,
                totalCount: 0
            )

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.textSecondary, Color.bgCard)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close preview")
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        #else
        .ignoresSafeArea()
        #endif
    }
}
#endif

private struct SettingsAppIcon: View {
    var body: some View {
        platformImage
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
    }

    private var platformImage: Image {
        #if os(macOS)
        return Image(nsImage: NSApplication.shared.applicationIconImage)
        #else
        if let image = UIImage(named: appIconName) {
            return Image(uiImage: image)
        } else {
            return Image(systemName: "app.fill")
        }
        #endif
    }

    #if os(iOS)
    private var appIconName: String {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        return files?.last ?? "AppIcon"
    }
    #endif
}

struct BackupShareItem: Identifiable {
    let id = UUID()
    let url: URL
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
