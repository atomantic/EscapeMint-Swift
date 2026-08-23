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
    nonisolated static let appGroupId = WidgetSharedStorage.appGroupId
    nonisolated static let snapshotFileName = WidgetSharedStorage.snapshotFileName

    private init() {}

    /// The App Group is a cross-process boundary: a standard `UserDefaults`
    /// value (and the Keychain-backed biometric setting) cannot be relied upon
    /// by the widget or an App Intent. Missing state therefore fails closed so
    /// an older sensitive snapshot is never treated as authorized.
    nonisolated static var externalPortfolioAccessIsLocked: Bool {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let locked = defaults.object(forKey: WidgetSharedStorage.externalPortfolioLockedKey) as? Bool else {
            return true
        }
        return locked
    }

    /// Revokes or grants extension access. When access is revoked the existing
    /// snapshot is removed immediately, rather than waiting for a recompute, so
    /// a widget cannot continue rendering stale portfolio values after lock.
    func setExternalPortfolioAccessLocked(_ locked: Bool) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupId) else {
            Self.logger.error("App Group defaults unavailable — leaving external portfolio access locked")
            return
        }
        defaults.set(locked, forKey: WidgetSharedStorage.externalPortfolioLockedKey)

        if locked {
            removeSnapshot()
        }
    }

    /// Write current portfolio state to the shared container
    func updateSnapshot() {
        guard !Self.externalPortfolioAccessIsLocked else {
            // Never leave an old value-bearing file behind while a biometric
            // lock is active. This also reloads widgets to their empty state.
            removeSnapshot()
            return
        }

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

    private func removeSnapshot() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else {
            return
        }

        let fileURL = containerURL.appendingPathComponent(Self.snapshotFileName)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            Self.logger.error("Failed to remove protected widget snapshot: \(error.localizedDescription)")
            // If removal was rejected, replace the file with an intentionally
            // undecodable payload. The widget then enters its no-data state
            // instead of rendering the prior value-bearing snapshot.
            do {
                try Data().write(to: fileURL, options: .atomic)
            } catch {
                Self.logger.error("Failed to redact protected widget snapshot: \(error.localizedDescription)")
            }
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Read snapshot from the shared container (called by the widget and by the
    /// App Intents). Resolves the real App Group container URL, then delegates to
    /// the directory-injectable overload below so tests can seed and assert a read.
    /// `nonisolated` because it touches only static `let` constants and the
    /// filesystem — no MainActor state — so intents running off the main actor
    /// (and in a separate process) can read it without a hop.
    nonisolated static func readSnapshot() -> WidgetSnapshot? {
        guard !externalPortfolioAccessIsLocked else { return nil }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        return readSnapshot(from: containerURL, externalAccessIsLocked: false)
    }

    /// Decode the snapshot stored in `containerURL` (the App Group container in
    /// production). Factored out so tests can point at a temp directory, seed a
    /// known `widget-snapshot.json`, and assert the decoded result — production
    /// behavior uses the App Group access state before decoding the real container.
    nonisolated static func readSnapshot(from containerURL: URL) -> WidgetSnapshot? {
        readSnapshot(from: containerURL, externalAccessIsLocked: externalPortfolioAccessIsLocked)
    }

    /// Directory- and access-state-injectable variant used to prove that a
    /// locked extension never decodes a previously written sensitive file.
    nonisolated static func readSnapshot(
        from containerURL: URL,
        externalAccessIsLocked: Bool
    ) -> WidgetSnapshot? {
        guard !externalAccessIsLocked else { return nil }
        let fileURL = containerURL.appendingPathComponent(snapshotFileName)
        return decodeJSONFile(fileURL, as: WidgetSnapshot.self)
    }
}

// WidgetSnapshot and WidgetFundSnapshot are defined in Shared/WidgetSnapshotModels.swift
