import Foundation

/// Shared transport details for the portfolio snapshot exchanged between the app,
/// App Intents, and widget extension.
enum WidgetSnapshotTransport {
    static let appGroupIdentifier = "group.net.shadowpuppet.EscapeMint"
    static let fileName = "widget-snapshot.json"

    /// Read the snapshot from the App Group container used in production.
    static func readSnapshot(fileManager: FileManager = .default) -> WidgetSnapshot? {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return readSnapshot(from: containerURL)
    }

    /// Read a snapshot from an injected container directory for deterministic tests.
    static func readSnapshot(from containerURL: URL) -> WidgetSnapshot? {
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
