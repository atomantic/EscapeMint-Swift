import Foundation
import UserNotifications
import os

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

    /// Toggle notifications on/off. Requests permission if enabling for the first time.
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

    /// Request notification authorization. Returns true if granted.
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

    /// Check current authorization status
    func checkAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    /// Cancel all scheduled DCA notifications
    func cancelAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: pendingIdentifiers
        )
        pendingIdentifiers = []
    }

    private var pendingIdentifiers: [String] = []

    /// Reschedule notifications for all active funds based on their DCA intervals
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
            content.userInfo = ["fundId": fund.id]

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

    /// Compute the next DCA date based on last entry + interval
    func computeNextDCADate(fund: FundData, intervalDays: Int) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        if let lastEntry = fund.entries.last {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let lastDate = formatter.date(from: lastEntry.date) {
                let nextDate = calendar.date(byAdding: .day, value: intervalDays, to: lastDate) ?? now
                // If next date is in the past, schedule for tomorrow at 9 AM
                if nextDate <= now {
                    var components = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
                    components.hour = 9
                    components.minute = 0
                    return calendar.date(from: components)
                }
                // Schedule at 9 AM on the computed date
                var components = calendar.dateComponents([.year, .month, .day], from: nextDate)
                components.hour = 9
                components.minute = 0
                return calendar.date(from: components)
            }
        }

        // No entries — schedule for tomorrow at 9 AM
        var components = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        components.hour = 9
        components.minute = 0
        return calendar.date(from: components)
    }
}
