import Foundation

extension Notification.Name {
    static let selectFund = Notification.Name("selectFund")
    static let selectDashboard = Notification.Name("selectDashboard")
    static let selectBacktest = Notification.Name("selectBacktest")
    static let selectPlatform = Notification.Name("selectPlatform")
    static let showAddEntry = Notification.Name("showAddEntry")
}

enum NotificationUserInfoKey {
    static let fundId = "fundId"
}
