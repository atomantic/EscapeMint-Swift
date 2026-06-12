import Combine
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

    /// Post `.selectBacktest` (no payload).
    func postSelectBacktest() {
        post(name: .selectBacktest, object: nil)
    }

    /// Post `.showCreateFund` (no payload).
    func postShowCreateFund() {
        post(name: .showCreateFund, object: nil)
    }

    /// Post `.fundsDidChange` (no payload).
    func postFundsDidChange() {
        post(name: .fundsDidChange, object: nil)
    }
}

// MARK: - Typed Observe Helpers

/// Typed publishers that extract the notification payload so observers receive
/// the value they care about (e.g. a fund id `String`) instead of a `Notification`
/// they have to `object as? String`. The string-payload publishers drop posts
/// whose `object` isn't a `String`, eliminating a class of silent navigation
/// drops from mismatched casts.
extension NotificationCenter {
    /// Publisher emitting the fund id for each `.selectFund` post.
    func selectFundPublisher() -> AnyPublisher<String, Never> {
        publisher(for: .selectFund)
            .compactMap { $0.object as? String }
            .eraseToAnyPublisher()
    }

    /// Publisher emitting the platform name for each `.selectPlatform` post.
    func selectPlatformPublisher() -> AnyPublisher<String, Never> {
        publisher(for: .selectPlatform)
            .compactMap { $0.object as? String }
            .eraseToAnyPublisher()
    }

    /// Publisher emitting the fund id for each `.showAddEntry` post.
    func showAddEntryPublisher() -> AnyPublisher<String, Never> {
        publisher(for: .showAddEntry)
            .compactMap { $0.object as? String }
            .eraseToAnyPublisher()
    }
}
