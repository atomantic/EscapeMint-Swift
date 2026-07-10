import Foundation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes a summary snapshot to the App Group container for the widget extension to read.
@MainActor
final class WidgetDataProvider {
    static let shared = WidgetDataProvider()
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "WidgetData")
    nonisolated static let appGroupId = "group.net.shadowpuppet.EscapeMint"
    nonisolated static let snapshotFileName = "widget-snapshot.json"

    private init() {}

    /// Write current portfolio state to the shared container
    func updateSnapshot() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else {
            Self.logger.error("⚠️ App Group container unavailable — widget data cannot be shared")
            return
        }

        let store = FundDataStore.shared
        let portfolio = store.portfolio
        let actionable = store.actionableFunds

        let topFunds: [WidgetFundSnapshot] = store.summaries
            .filter { $0.fund.config.status != .closed }
            .prefix(7)
            .map { summary in
                WidgetFundSnapshot(
                    ticker: summary.fund.ticker.uppercased(),
                    platform: summary.fund.platform.capitalized,
                    value: summary.currentValue,
                    gainPct: summary.metrics.gainPct,
                    isDueForAction: summary.isDueForAction,
                    recommendedAction: summary.recommendation?.action.rawValue,
                    recommendedAmount: summary.recommendation?.amount
                )
            }

        let snapshot = WidgetSnapshot(
            totalValue: portfolio.totalValue,
            totalGainUsd: portfolio.totalGainUsd,
            totalGainPct: portfolio.totalGainPct,
            activeFunds: portfolio.activeFunds,
            actionableCount: actionable.count,
            topFunds: topFunds,
            updatedAt: Date()
        )

        let fileURL = containerURL.appendingPathComponent(Self.snapshotFileName)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            // Widget extensions cannot read `.complete` files when the device is locked.
            // `.completeUntilFirstUserAuthentication` lets the widget keep rendering after
            // first unlock while still protecting the snapshot at rest.
            // If the attribute call fails (unexpected container behavior / filesystem error),
            // log it — the snapshot is still written, but its protection class defaulted to
            // `.none` and that's an operational concern worth surfacing.
            #if os(iOS)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                Self.logger.warning("Failed to apply file protection to widget snapshot: \(error.localizedDescription, privacy: .public)")
            }
            #endif
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        } catch {
            Self.logger.error("Failed to write widget snapshot: \(error.localizedDescription)")
        }
    }

    /// Read snapshot from the shared container (called by the widget and by the
    /// App Intents). Resolves the real App Group container URL, then delegates to
    /// the directory-injectable overload below so tests can seed and assert a read.
    /// `nonisolated` because it touches only static `let` constants and the
    /// filesystem — no MainActor state — so intents running off the main actor
    /// (and in a separate process) can read it without a hop.
    nonisolated static func readSnapshot() -> WidgetSnapshot? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        return readSnapshot(from: containerURL)
    }

    /// Decode the snapshot stored in `containerURL` (the App Group container in
    /// production). Factored out so tests can point at a temp directory, seed a
    /// known `widget-snapshot.json`, and assert the decoded result — production
    /// behavior is unchanged because `readSnapshot()` passes the real container.
    nonisolated static func readSnapshot(from containerURL: URL) -> WidgetSnapshot? {
        let fileURL = containerURL.appendingPathComponent(snapshotFileName)
        return decodeJSONFile(fileURL, as: WidgetSnapshot.self)
    }
}

// WidgetSnapshot and WidgetFundSnapshot are defined in Shared/WidgetSnapshotModels.swift
