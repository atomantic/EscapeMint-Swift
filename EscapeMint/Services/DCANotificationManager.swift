import Foundation
import UserNotifications
import os

/// Handles notification tap responses — must be NSObject for UNUserNotificationCenterDelegate.
/// Set as delegate before any notifications can arrive (in EscapeMintApp.init).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let fundId = userInfo[NotificationUserInfoKey.fundId] as? String
        if let fundId {
            Task { @MainActor in
                NotificationCenter.default.postSelectFund(id: fundId)
            }
        }
        // Acknowledge delivery on the delegate callback before hopping to the
        // main actor; the non-Sendable completion must not cross actor domains.
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

/// Seam over the subset of `UNUserNotificationCenter` that `DCANotificationManager`
/// touches, so tests can inject a fake center (the system center can't be authorized
/// or inspected from a unit test). Production uses `SystemNotificationCenter`, a thin
/// pass-through to `UNUserNotificationCenter.current()`, so behavior is unchanged.
@MainActor
protocol NotificationScheduling {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func removeAllPendingNotificationRequests()
}

/// Production seam: forwards every call to the real `UNUserNotificationCenter`.
@MainActor
struct SystemNotificationCenter: NotificationScheduling {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
    func removeAllPendingNotificationRequests() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

@MainActor @Observable
final class DCANotificationManager {
    static let shared = DCANotificationManager()

    private(set) var isAuthorized = false
    private(set) var isEnabled: Bool
    /// Set when a permission request was denied. SettingsView shows a toast
    /// and clears this to dismiss. Without it, a permission denial would
    /// leave the Toggle visually-on (optimistic binding flip) with no
    /// notifications actually scheduled.
    var permissionDeniedMessage: String?

    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "DCANotifications")
    private static let categoryId = "DCA_REMINDER"

    /// Injected notification center (defaults to the real system center). Tests pass a
    /// fake to drive permission grant/denial and inspect scheduled requests.
    private let center: NotificationScheduling
    /// Source of funds for `rescheduleAll`. Defaults to the shared store; tests inject a
    /// fixed list so scheduling assertions don't depend on on-disk data.
    private let fundsProvider: @MainActor () -> [FundData]

    private init() {
        self.center = SystemNotificationCenter()
        self.fundsProvider = { FundDataStore.shared.funds }
        self.isEnabled = UserDefaults.standard.bool(forKey: AppStorageKeys.dcaNotifications)
    }

    /// Test-only initializer: injects a notification-center seam and a fixed funds list.
    /// Production code always uses `shared`, which wires the real system center + store.
    init(center: NotificationScheduling,
         isEnabled: Bool = true,
         fundsProvider: @escaping @MainActor () -> [FundData] = { [] }) {
        self.center = center
        self.fundsProvider = fundsProvider
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await requestPermission()
            if !granted {
                Self.logger.info("Notification permission denied")
                isEnabled = false
                UserDefaults.standard.set(false, forKey: AppStorageKeys.dcaNotifications)
                permissionDeniedMessage = "Enable notifications in System Settings to use DCA reminders."
                return
            }
            isAuthorized = true
            isEnabled = true
            UserDefaults.standard.set(true, forKey: AppStorageKeys.dcaNotifications)
            await rescheduleAll()
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: AppStorageKeys.dcaNotifications)
            cancelAll()
        }
    }

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted
            return granted
        } catch {
            Self.logger.error("Notification auth error: \(error.localizedDescription)")
            return false
        }
    }

    func checkAuthorization() async {
        let status = await center.currentAuthorizationStatus()
        isAuthorized = status == .authorized
    }

    func cancelAll() {
        // DCA reminders are the only notifications this app schedules, so a full
        // clear is safe — and crucially this also removes requests scheduled in
        // a prior launch (the `pendingIdentifiers` in-memory array is empty on
        // a fresh launch, so the previous per-id removal would silently leak
        // stale reminders after the user toggles reminders off).
        center.removeAllPendingNotificationRequests()
        pendingIdentifiers = []
    }

    private var pendingIdentifiers: [String] = []

    /// Identifiers of notifications scheduled in the current session. Exposed for tests
    /// to assert scheduling correctness; production code only mutates it internally.
    var scheduledIdentifiers: [String] { pendingIdentifiers }

    func rescheduleAll() async {
        guard isEnabled else { return }
        await checkAuthorization()
        guard isAuthorized else { return }

        cancelAll()

        let funds = fundsProvider().filter { $0.config.status != .closed }
        var identifiers: [String] = []

        for fund in funds {
            guard let intervalDays = fund.config.interval_days, intervalDays > 0 else { continue }
            guard let fundType = fund.config.fund_type, !isCashFund(fundType) else { continue }
            if fundType == .derivatives { continue }

            let nextDate = computeNextDCADate(fund: fund, intervalDays: intervalDays)
            guard let fireDate = nextDate else { continue }

            // Intentionally omit the recommended dollar amount — notification bodies render
            // on the lock screen and Notification Center without biometric auth, so leaking
            // a user's DCA size would expose PII. Users see the amount after unlocking the app.
            let content = UNMutableNotificationContent()
            content.title = "DCA Reminder: \(fund.ticker.uppercased())"
            content.body = "Time to review your \(fund.ticker.uppercased()) position on \(fund.platform.capitalized)"
            content.sound = .default
            content.categoryIdentifier = Self.categoryId
            content.userInfo = [NotificationUserInfoKey.fundId: fund.id]

            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            let identifier = "dca-\(fund.id)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            do {
                try await center.add(request)
                identifiers.append(identifier)
                Self.logger.info("Scheduled DCA notification for \(fund.ticker, privacy: .private) on \(fireDate, privacy: .private)")
            } catch {
                Self.logger.error("Failed to schedule notification for \(fund.ticker, privacy: .private): \(error.localizedDescription)")
            }
        }

        pendingIdentifiers = identifiers
    }

    func computeNextDCADate(fund: FundData, intervalDays: Int) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let fundType = fund.config.fund_type

        let rawDate: Date
        if let lastEntry = fund.entries.last,
           let lastDate = isoDateFormatter.date(from: lastEntry.date) {
            let nextDate = calendar.date(byAdding: .day, value: intervalDays, to: lastDate) ?? now
            rawDate = nextDate <= now
                ? (calendar.date(byAdding: .day, value: 1, to: now) ?? now)
                : nextDate
        } else {
            // No entries — schedule for tomorrow
            rawDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        }

        // Stock funds: advance to next trading day (skip weekends/holidays)
        let fireDate = nextTradingDay(from: rawDate, fundType: fundType)
        return atNineAM(fireDate)
    }

    private func atNineAM(_ date: Date) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components)
    }
}
