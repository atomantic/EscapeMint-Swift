import Foundation

enum AppStorageKeys {
    static let introCompleted = "escapemint-intro-completed"
    static let showIntroOnLaunch = "escapemint-show-intro-on-launch"
    static let advancedTools = "escapemint-advanced-tools"
    static let biometricAuth = "escapemint-biometric-auth"
    /// Stored in the App Group defaults so widgets and App Intents can safely
    /// decide whether the shared portfolio snapshot may be read. This is
    /// deliberately separate from `biometricAuth`, which lives in Keychain and
    /// is not an extension-safe cross-process signal.
    static let externalPortfolioLocked = "escapemint-external-portfolio-locked"
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
