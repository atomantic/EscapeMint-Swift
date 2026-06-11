import Foundation

enum AppStorageKeys {
    static let introCompleted = "escapemint-intro-completed"
    static let showIntroOnLaunch = "escapemint-show-intro-on-launch"
    static let advancedTools = "escapemint-advanced-tools"
    static let biometricAuth = "escapemint-biometric-auth"
    static let dcaNotifications = "escapemint-dca-notifications"
    static let appearanceMode = "appearanceMode"
    static let sidebarCollapsed = "escapemint-sidebar-collapsed"
    static let dashboardCollapsed = "escapemint-dashboard-collapsed"
    static let advancedEntryMode = "escapemint-advanced-entry-mode"

    /// Per-fund toggle for showing the optional fields section in Add Entry.
    static func addEntryShowOptional(fundId: String) -> String {
        "addEntry_showOptional_\(fundId)"
    }
}
