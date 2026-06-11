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
    static let appGroupId = "group.net.shadowpuppet.EscapeMint"
    static let snapshotFileName = "widget-snapshot.json"

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

    /// Read snapshot from the shared container (called by widget)
    static func readSnapshot() -> WidgetSnapshot? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let fileURL = containerURL.appendingPathComponent(snapshotFileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

// WidgetSnapshot and WidgetFundSnapshot are defined in Shared/WidgetSnapshotModels.swift
