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
        if let fundId = userInfo[NotificationUserInfoKey.fundId] as? String {
            NotificationCenter.default.post(name: .selectFund, object: fundId)
        }
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

@MainActor @Observable
final class DCANotificationManager {
    static let shared = DCANotificationManager()

    private(set) var isAuthorized = false
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "DCANotifications")
    private static let categoryId = "DCA_REMINDER"

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "escapemint-dca-notifications")
    }

    private init() {}

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await requestPermission()
            if !granted {
                Self.logger.info("Notification permission denied")
                return
            }
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: "escapemint-dca-notifications")
            await rescheduleAll()
        } else {
            UserDefaults.standard.set(false, forKey: "escapemint-dca-notifications")
            cancelAll()
        }
    }

    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
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
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: pendingIdentifiers
        )
        pendingIdentifiers = []
    }

    private var pendingIdentifiers: [String] = []

    func rescheduleAll() async {
        guard isEnabled else { return }
        await checkAuthorization()
        guard isAuthorized else { return }

        cancelAll()

        let store = FundDataStore.shared
        let funds = store.funds.filter { $0.config.status != .closed }
        var identifiers: [String] = []

        for fund in funds {
            guard let intervalDays = fund.config.interval_days, intervalDays > 0 else { continue }
            guard let fundType = fund.config.fund_type, !isCashFund(fundType) else { continue }
            if fundType == .derivatives { continue }

            let nextDate = computeNextDCADate(fund: fund, intervalDays: intervalDays)
            guard let fireDate = nextDate else { continue }

            let summary = store.summary(byId: fund.id)
            let amount = summary?.recommendation?.amount ?? fund.config.input_mid_usd ?? 0
            let amountStr = amount > 0 ? " — $\(Int(amount)) recommended" : ""

            let content = UNMutableNotificationContent()
            content.title = "DCA Reminder: \(fund.ticker.uppercased())"
            content.body = "Time to DCA into \(fund.ticker.uppercased()) on \(fund.platform.capitalized)\(amountStr)"
            content.sound = .default
            content.categoryIdentifier = Self.categoryId
            content.userInfo = [NotificationUserInfoKey.fundId: fund.id]

            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            let identifier = "dca-\(fund.id)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            do {
                try await UNUserNotificationCenter.current().add(request)
                identifiers.append(identifier)
                Self.logger.info("Scheduled DCA notification for \(fund.ticker) on \(fireDate)")
            } catch {
                Self.logger.error("Failed to schedule notification for \(fund.ticker): \(error.localizedDescription)")
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
