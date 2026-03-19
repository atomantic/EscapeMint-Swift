import Foundation
import Combine
import os

/// Monitors the iCloud ubiquity container for file changes from other devices
/// and triggers a reload of FundDataStore when changes are detected.
@MainActor
final class ICloudSyncMonitor {
    static let shared = ICloudSyncMonitor()

    private var query: NSMetadataQuery?
    private var debounceTask: Task<Void, Never>?
    private var lastReloadDate = Date.distantPast
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "ICloudSync")

    /// Minimum interval between reloads to avoid thrashing during bulk sync
    private let debounceInterval: TimeInterval = 2.0

    private(set) var isSyncing = false

    private init() {}

    /// Start monitoring iCloud container for changes. Call once after initial load.
    func startMonitoring() {
        guard FundStore.shared.isICloud else {
            Self.logger.info("☁️ not using iCloud, skipping sync monitor")
            return
        }
        guard query == nil else { return }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery.predicate = NSPredicate(format: "%K LIKE '*.tsv' OR %K LIKE '*.json'",
                                               NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)

        NotificationCenter.default.addObserver(
            self, selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate, object: metadataQuery
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryDidFinishGathering),
            name: .NSMetadataQueryDidFinishGathering, object: metadataQuery
        )

        metadataQuery.start()
        query = metadataQuery
        Self.logger.info("☁️ iCloud sync monitor started")
    }

    func stopMonitoring() {
        query?.stop()
        query = nil
        debounceTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// Manual sync — force reload from disk (iCloud files)
    func syncNow() async {
        Self.logger.info("☁️ manual sync triggered")
        isSyncing = true
        await FundDataStore.shared.reload()
        lastReloadDate = Date()
        isSyncing = false
        NotificationCenter.default.post(name: .fundsDidChange, object: nil)
    }

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        // Initial gather complete — don't reload since we already loaded at startup
        Self.logger.info("☁️ initial iCloud gather complete")
        query?.enableUpdates()
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        // Files changed in iCloud — debounce to avoid rapid-fire reloads
        Self.logger.info("☁️ iCloud files changed, scheduling reload")
        scheduleReload()
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(debounceInterval))
            guard !Task.isCancelled else { return }

            // Skip if we just reloaded (e.g. from our own writes)
            let elapsed = Date().timeIntervalSince(lastReloadDate)
            guard elapsed > debounceInterval else {
                Self.logger.info("☁️ skipping reload, last reload was \(String(format: "%.1f", elapsed))s ago")
                return
            }

            Self.logger.info("☁️ reloading from iCloud changes")
            isSyncing = true
            await FundDataStore.shared.reload()
            lastReloadDate = Date()
            isSyncing = false
            NotificationCenter.default.post(name: .fundsDidChange, object: nil)
        }
    }

    /// Call after local writes to prevent re-triggering a reload from our own changes
    func markLocalWrite() {
        lastReloadDate = Date()
    }
}
