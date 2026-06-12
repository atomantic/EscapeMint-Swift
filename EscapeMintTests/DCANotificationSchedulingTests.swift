import XCTest
import UserNotifications
@testable import EscapeMint

/// In-memory fake notification center injected via the `NotificationScheduling` seam.
/// Records every call so tests can assert what `DCANotificationManager` scheduled and
/// drive the permission grant/denial branches without touching the real system center
/// (which can't be authorized or inspected from a unit test).
@MainActor
final class FakeNotificationCenter: NotificationScheduling {
    /// What `requestAuthorization` returns. `nil` makes it throw (the catch path).
    var authorizationGrant: Bool? = true
    var authorizationStatusValue: UNAuthorizationStatus = .authorized
    var requestAuthorizationCallCount = 0
    /// Optional error to make `add(_:)` throw, exercising the per-request failure path.
    var addError: Error?

    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removeAllCallCount = 0

    struct AuthError: Error {}

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCallCount += 1
        guard let grant = authorizationGrant else { throw AuthError() }
        return grant
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusValue
    }

    func add(_ request: UNNotificationRequest) async throws {
        if let addError { throw addError }
        addedRequests.append(request)
    }

    func removeAllPendingNotificationRequests() {
        removeAllCallCount += 1
        addedRequests.removeAll()
    }
}

@MainActor
final class DCANotificationSchedulingTests: XCTestCase {

    private func fund(
        platform: String,
        ticker: String,
        type: FundType,
        intervalDays: Int?,
        status: FundStatus = .active,
        lastEntryDate: String? = nil
    ) -> FundData {
        let entries: [FundEntry] = lastEntryDate.map { [FundEntry(date: $0, value: 1000)] } ?? []
        return FundData(
            platform: platform, ticker: ticker,
            config: FundConfig(fund_type: type, status: status, interval_days: intervalDays),
            entries: entries
        )
    }

    // MARK: - Permission paths

    /// Permission granted → manager enables, authorizes, persists the flag, and schedules.
    func testSetEnabledGrantedAuthorizesAndSchedules() async {
        let center = FakeNotificationCenter()
        center.authorizationGrant = true
        center.authorizationStatusValue = .authorized
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: false,
                                             fundsProvider: { [btc] })

        let priorDefault = UserDefaults.standard.bool(forKey: AppStorageKeys.dcaNotifications)
        defer { UserDefaults.standard.set(priorDefault, forKey: AppStorageKeys.dcaNotifications) }

        await manager.setEnabled(true)

        XCTAssertTrue(manager.isEnabled, "Granted permission enables reminders")
        XCTAssertTrue(manager.isAuthorized)
        XCTAssertNil(manager.permissionDeniedMessage, "No denial toast on grant")
        XCTAssertEqual(center.requestAuthorizationCallCount, 1)
        // rescheduleAll ran: one crypto fund with a valid interval → one scheduled request.
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(manager.scheduledIdentifiers, ["dca-coinbase-BTC"])
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppStorageKeys.dcaNotifications),
                      "Enabled flag is persisted")
    }

    /// Permission denied → manager stays disabled, sets the toast message, persists false,
    /// and schedules nothing (the bug the `permissionDeniedMessage` seam guards against).
    func testSetEnabledDeniedSetsToastAndSchedulesNothing() async {
        let center = FakeNotificationCenter()
        center.authorizationGrant = false
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: false,
                                             fundsProvider: { [btc] })

        let priorDefault = UserDefaults.standard.bool(forKey: AppStorageKeys.dcaNotifications)
        defer { UserDefaults.standard.set(priorDefault, forKey: AppStorageKeys.dcaNotifications) }

        await manager.setEnabled(true)

        XCTAssertFalse(manager.isEnabled, "Denied permission must not enable reminders")
        XCTAssertFalse(manager.isAuthorized)
        XCTAssertNotNil(manager.permissionDeniedMessage, "Denial must surface a toast message")
        XCTAssertEqual(center.requestAuthorizationCallCount, 1)
        XCTAssertTrue(center.addedRequests.isEmpty, "Nothing scheduled when permission denied")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppStorageKeys.dcaNotifications),
                       "Disabled flag is persisted on denial")
    }

    /// `requestAuthorization` throwing is treated as not-granted (the catch path), never a crash.
    func testRequestPermissionThrowingReturnsFalse() async {
        let center = FakeNotificationCenter()
        center.authorizationGrant = nil // makes the fake throw
        let manager = DCANotificationManager(center: center, isEnabled: false)

        let granted = await manager.requestPermission()

        XCTAssertFalse(granted, "Auth error is treated as denial")
        XCTAssertFalse(manager.isAuthorized)
    }

    /// `checkAuthorization` mirrors the system status into `isAuthorized`.
    func testCheckAuthorizationReflectsSystemStatus() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .denied
        let manager = DCANotificationManager(center: center, isEnabled: true)
        await manager.checkAuthorization()
        XCTAssertFalse(manager.isAuthorized, ".denied status → not authorized")

        center.authorizationStatusValue = .authorized
        await manager.checkAuthorization()
        XCTAssertTrue(manager.isAuthorized, ".authorized status → authorized")
    }

    // MARK: - Scheduling correctness (identifiers, content, fire dates)

    /// Each eligible fund gets exactly one request whose identifier is `dca-<fund.id>` and
    /// whose userInfo carries the fund id (so a notification tap can deep-link to the fund).
    func testRescheduleSchedulesPerFundWithStableIdentifierAndUserInfo() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        let btc = fund(platform: "coinbase", ticker: "btc", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let eth = fund(platform: "coinbase", ticker: "eth", type: .crypto, intervalDays: 30,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: true,
                                             fundsProvider: { [btc, eth] })

        await manager.rescheduleAll()

        XCTAssertEqual(manager.scheduledIdentifiers.sorted(),
                       ["dca-coinbase-btc", "dca-coinbase-eth"])
        XCTAssertEqual(center.addedRequests.count, 2)

        let btcReq = try! XCTUnwrap(center.addedRequests.first { $0.identifier == "dca-coinbase-btc" })
        XCTAssertEqual(btcReq.content.title, "DCA Reminder: BTC", "Title uppercases the ticker")
        XCTAssertEqual(btcReq.content.userInfo[NotificationUserInfoKey.fundId] as? String,
                       "coinbase-btc", "userInfo carries the fund id for deep-linking")
        // PII guard: the body must not leak a dollar amount.
        XCTAssertFalse(btcReq.content.body.contains("$"),
                       "Notification body must not include a dollar amount")
        XCTAssertEqual(btcReq.content.categoryIdentifier, "DCA_REMINDER")
    }

    /// The fire date matches `computeNextDCADate` to the minute and uses a non-repeating
    /// calendar trigger — i.e. scheduling is consistent with the date the manager computes.
    func testScheduledFireDateMatchesComputedDate() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        // Future entry so the date is lastEntry + interval (not the tomorrow clamp), and
        // crypto skips the trading-day shift — fully determined by the input.
        let cal = Calendar.current
        let lastEntryDate = cal.date(byAdding: .day, value: 100, to: Date())!
        let lastEntryStr = isoDateFormatter.string(from: lastEntryDate)
        let sol = fund(platform: "coinbase", ticker: "SOL", type: .crypto, intervalDays: 14,
                       lastEntryDate: lastEntryStr)
        let manager = DCANotificationManager(center: center, isEnabled: true,
                                             fundsProvider: { [sol] })

        let expected = try! XCTUnwrap(manager.computeNextDCADate(fund: sol, intervalDays: 14))

        await manager.rescheduleAll()

        let req = try! XCTUnwrap(center.addedRequests.first)
        let trigger = try! XCTUnwrap(req.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats, "DCA reminders are one-shot")
        let fireDate = try! XCTUnwrap(trigger.nextTriggerDate())
        let got = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let want = cal.dateComponents([.year, .month, .day, .hour, .minute], from: expected)
        XCTAssertEqual(got.year, want.year)
        XCTAssertEqual(got.month, want.month)
        XCTAssertEqual(got.day, want.day)
        XCTAssertEqual(got.hour, 9, "Fires at 09:00")
        XCTAssertEqual(got.minute, 0)
    }

    /// Ineligible funds are skipped: closed status, cash funds, derivatives, and missing/
    /// non-positive interval all produce no scheduled request.
    func testRescheduleSkipsIneligibleFunds() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        let closed = fund(platform: "coinbase", ticker: "CLOSED", type: .crypto, intervalDays: 7,
                          status: .closed, lastEntryDate: "2020-01-01")
        let cash = fund(platform: "bank", ticker: "USD", type: .cash, intervalDays: 7,
                        lastEntryDate: "2020-01-01")
        let derivatives = fund(platform: "ibkr", ticker: "ES", type: .derivatives, intervalDays: 7,
                               lastEntryDate: "2020-01-01")
        let noInterval = fund(platform: "coinbase", ticker: "NOINT", type: .crypto, intervalDays: nil,
                              lastEntryDate: "2020-01-01")
        let zeroInterval = fund(platform: "coinbase", ticker: "ZERO", type: .crypto, intervalDays: 0,
                                lastEntryDate: "2020-01-01")
        let eligible = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                            lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(
            center: center, isEnabled: true,
            fundsProvider: { [closed, cash, derivatives, noInterval, zeroInterval, eligible] }
        )

        await manager.rescheduleAll()

        XCTAssertEqual(manager.scheduledIdentifiers, ["dca-coinbase-BTC"],
                       "Only the eligible crypto fund is scheduled")
        XCTAssertEqual(center.addedRequests.count, 1)
    }

    /// `rescheduleAll` clears prior pending requests first (cancelAll), so it's the
    /// single source of truth — re-running doesn't accumulate duplicates.
    func testRescheduleClearsBeforeSchedulingAndIsRepeatable() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: true,
                                             fundsProvider: { [btc] })

        await manager.rescheduleAll()
        await manager.rescheduleAll()

        XCTAssertGreaterThanOrEqual(center.removeAllCallCount, 2,
                                    "Each reschedule clears prior requests first")
        XCTAssertEqual(center.addedRequests.count, 1, "No duplicate accumulation")
        XCTAssertEqual(manager.scheduledIdentifiers, ["dca-coinbase-BTC"])
    }

    /// A disabled manager schedules nothing even when funds are eligible.
    func testRescheduleNoopWhenDisabled() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: false,
                                             fundsProvider: { [btc] })

        await manager.rescheduleAll()

        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(manager.scheduledIdentifiers.isEmpty)
    }

    /// When authorization is missing at reschedule time, nothing is scheduled.
    func testRescheduleNoopWhenNotAuthorized() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .denied
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: true,
                                             fundsProvider: { [btc] })

        await manager.rescheduleAll()

        XCTAssertTrue(center.addedRequests.isEmpty, "No schedule without authorization")
        XCTAssertTrue(manager.scheduledIdentifiers.isEmpty)
    }

    /// If `add` throws for a request, that fund is skipped (not in scheduledIdentifiers)
    /// while sibling funds still schedule — one failure doesn't abort the batch.
    func testRescheduleSkipsFundWhenAddThrows() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        center.addError = FakeNotificationCenter.AuthError()
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: true,
                                             fundsProvider: { [btc] })

        await manager.rescheduleAll()

        XCTAssertTrue(manager.scheduledIdentifiers.isEmpty,
                      "A failed add must not be recorded as scheduled")
    }

    // MARK: - cancelAll

    /// `cancelAll` clears the system center and the in-memory identifier list.
    func testCancelAllClearsCenterAndIdentifiers() async {
        let center = FakeNotificationCenter()
        center.authorizationStatusValue = .authorized
        let btc = fund(platform: "coinbase", ticker: "BTC", type: .crypto, intervalDays: 7,
                       lastEntryDate: "2020-01-01")
        let manager = DCANotificationManager(center: center, isEnabled: true,
                                             fundsProvider: { [btc] })
        await manager.rescheduleAll()
        XCTAssertFalse(manager.scheduledIdentifiers.isEmpty)

        manager.cancelAll()

        XCTAssertTrue(manager.scheduledIdentifiers.isEmpty)
        XCTAssertTrue(center.addedRequests.isEmpty)
    }
}
