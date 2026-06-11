#if os(macOS)
import AppKit

/// macOS dock-tile badge showing the count of actionable funds. Lives in the app/service
/// layer and is driven by a `FundDataStore` recompute observer, so the data store no
/// longer touches `NSApp` / AppKit directly.
@MainActor
enum StoreDockBadge {
    static func update(actionableCount: Int) {
        NSApp?.dockTile.badgeLabel = actionableCount > 0 ? "\(actionableCount)" : nil
    }
}
#endif
