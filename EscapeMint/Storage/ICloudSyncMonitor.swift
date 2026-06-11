import Foundation
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Monitors the iCloud ubiquity container for file changes from other devices
/// and triggers a reload of FundDataStore when changes are detected.
@MainActor @Observable
final class ICloudSyncMonitor {
    static let shared = ICloudSyncMonitor()

    private var query: NSMetadataQuery?
    /// Idempotency guard: set true once observers are registered, reset in `stopMonitoring`.
    /// Prevents a double `startMonitoring()` call from double-registering NotificationCenter
    /// observers (which would fire each selector twice per change).
    private var isMonitoring = false
    private var debounceTask: Task<Void, Never>?
    private var lastWriteDate = Date.distantPast
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "ICloudSync")

    /// Minimum interval between reloads to avoid thrashing during bulk sync
    private let debounceInterval: TimeInterval = 2.0

    /// Window after a local write during which we suppress reload from our own iCloud changes
    private let writeSuppressionWindow: TimeInterval = 5.0

    private(set) var isSyncing = false

    private init() {}

    /// Start monitoring iCloud container for changes. Call once after initial load.
    func startMonitoring() {
        guard FundStore.shared.isICloud else {
            Self.logger.info("☁️ not using iCloud, skipping sync monitor")
            return
        }
        guard !isMonitoring, query == nil else { return }
        isMonitoring = true

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
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        #else
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterForeground),
            name: NSApplication.willBecomeActiveNotification, object: nil
        )
        #endif

        metadataQuery.start()
        query = metadataQuery
        Self.logger.info("☁️ iCloud sync monitor started")
    }

    func stopMonitoring() {
        query?.stop()
        query = nil
        debounceTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        isMonitoring = false
    }

    /// Manual sync — force reload from disk (iCloud files)
    func syncNow() async {
        Self.logger.info("☁️ manual sync triggered")
        isSyncing = true
        await FundDataStore.shared.reload()
        isSyncing = false
    }

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        query?.enableUpdates()
        Self.logger.info("☁️ initial iCloud gather complete")
        // Trigger download for any evicted iCloud placeholders, then schedule a
        // reload — covers fresh installs where files exist in iCloud but haven't
        // been downloaded to this device yet.
        triggerEvictedDownloads()
        scheduleReload()
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        Self.logger.info("☁️ iCloud files changed, scheduling reload")
        scheduleReload()
    }

    @objc private func appDidEnterForeground(_ notification: Notification) {
        Self.logger.info("☁️ app foregrounded — scheduling proactive iCloud sync")
        scheduleReload()
    }

    private func triggerEvictedDownloads() {
        guard let items = query?.results as? [NSMetadataItem] else { return }
        let fm = FileManager.default
        for item in items {
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            guard status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            try? fm.startDownloadingUbiquitousItem(at: url)
            Self.logger.info("☁️ triggered download for evicted iCloud file: \(url.lastPathComponent, privacy: .public)")
        }
    }

    /// True while a `reload()` call is actually in progress. `debounceTask?.cancel()`
    /// only stops a task that's still sleeping — if it's past the sleep and running
    /// the reload body, cancel is a no-op and a second scheduled reload would
    /// execute back-to-back. Gate on this flag to coalesce overlaps.
    private var isReloadInFlight = false

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(debounceInterval))
            guard !Task.isCancelled else { return }

            // Skip if this change is likely from our own recent write
            let sinceLastWrite = Date().timeIntervalSince(lastWriteDate)
            guard sinceLastWrite > writeSuppressionWindow else {
                Self.logger.info("☁️ skipping reload, local write was \(String(format: "%.1f", sinceLastWrite))s ago")
                return
            }

            guard !isReloadInFlight else {
                Self.logger.info("☁️ reload already in flight — coalescing")
                return
            }

            isReloadInFlight = true
            isSyncing = true
            Self.logger.info("☁️ reloading from iCloud changes")
            await FundDataStore.shared.reload()
            isSyncing = false
            isReloadInFlight = false
        }
    }

    /// Call after local writes to suppress reload from our own iCloud changes
    func markLocalWrite() {
        lastWriteDate = Date()
    }
}
