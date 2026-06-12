import Foundation

extension Notification.Name {
    static let selectFund = Notification.Name("selectFund")
    static let selectDashboard = Notification.Name("selectDashboard")
    static let selectBacktest = Notification.Name("selectBacktest")
    static let selectPlatform = Notification.Name("selectPlatform")
    static let showAddEntry = Notification.Name("showAddEntry")
    static let showCreateFund = Notification.Name("showCreateFund")
    static let fundsDidChange = Notification.Name("fundsDidChange")
}

enum NotificationUserInfoKey {
    static let fundId = "fundId"
}

// MARK: - Typed Post Helpers

/// Typed wrappers around the navigation notifications so call sites don't pass a
/// loosely-typed `object:` (and observers don't have to `object as? String`).
/// The payload remains the notification `object` for source compatibility with
/// existing observers; the helpers just make intent explicit at the post site.
extension NotificationCenter {
    /// Post `.selectFund` carrying the fund id.
    func postSelectFund(id: String) {
        post(name: .selectFund, object: id)
    }

    /// Post `.selectPlatform` carrying the platform name.
    func postSelectPlatform(name: String) {
        post(name: .selectPlatform, object: name)
    }

    /// Post `.showAddEntry` carrying the fund id.
    func postShowAddEntry(id: String) {
        post(name: .showAddEntry, object: id)
    }

    /// Post `.selectDashboard` (no payload).
    func postSelectDashboard() {
        post(name: .selectDashboard, object: nil)
    }

    /// Post `.showCreateFund` (no payload).
    func postShowCreateFund() {
        post(name: .showCreateFund, object: nil)
    }
}
