import Foundation

/// Shared transport details for the portfolio snapshot exchanged between the app,
/// App Intents, and widget extension.
enum WidgetSnapshotTransport {
    static let appGroupIdentifier = "group.net.shadowpuppet.EscapeMint"
    static let fileName = "widget-snapshot.json"

    static let externalPortfolioLockedKey = "escapemint-external-portfolio-locked"

    /// Missing cross-process authorization fails closed, including legacy snapshots.
    static var externalPortfolioAccessIsLocked: Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let locked = defaults.object(forKey: externalPortfolioLockedKey) as? Bool else {
            return true
        }
        return locked
    }

    /// Read the snapshot from the App Group container used in production.
    static func readSnapshot(fileManager: FileManager = .default) -> WidgetSnapshot? {
        guard !externalPortfolioAccessIsLocked else { return nil }
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return readSnapshot(from: containerURL, externalAccessIsLocked: false)
    }

    /// Read a snapshot from an injected container directory for deterministic tests.
    static func readSnapshot(
        from containerURL: URL,
        externalAccessIsLocked: Bool = externalPortfolioAccessIsLocked
    ) -> WidgetSnapshot? {
        guard !externalAccessIsLocked else { return nil }
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
