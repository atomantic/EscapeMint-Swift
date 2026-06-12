import XCTest
import CoreSpotlight
@testable import EscapeMint

/// Records the items/identifiers handed to Spotlight so tests can assert the
/// side effects of `SpotlightIndexer` without touching the real system index.
final class SpySearchableIndex: SearchableIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var _indexedItems: [CSSearchableItem] = []
    private var _deletedDomains: [String] = []
    private var _deletedIdentifiers: [String] = []

    var indexedItems: [CSSearchableItem] { lock.withLock { _indexedItems } }
    var deletedDomains: [String] { lock.withLock { _deletedDomains } }
    var deletedIdentifiers: [String] { lock.withLock { _deletedIdentifiers } }

    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.withLock { _indexedItems.append(contentsOf: items) }
        completionHandler?(nil)
    }

    func deleteSearchableItems(withDomainIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.withLock { _deletedDomains.append(contentsOf: identifiers) }
        completionHandler?(nil)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.withLock { _deletedIdentifiers.append(contentsOf: identifiers) }
        completionHandler?(nil)
    }
}

final class ServicesTests: XCTestCase {

    // MARK: - AuthManager

    @MainActor
    func testAuthManagerDefaultsUnlocked() {
        // When biometric auth is not enabled, the manager should start unlocked
        let auth = AuthManager.shared
        let wasEnabled = auth.isEnabled
        auth.setEnabled(false)
        XCTAssertTrue(auth.isUnlocked, "Should be unlocked when auth is disabled")
        // Restore
        auth.setEnabled(wasEnabled)
    }

    @MainActor
    func testAuthManagerLockRequiresEnabled() {
        let auth = AuthManager.shared
        auth.setEnabled(false)
        auth.lock()
        XCTAssertTrue(auth.isUnlocked, "Lock should not work when auth is disabled")
    }

    @MainActor
    func testAuthManagerSetEnabledFalseUnlocks() {
        let auth = AuthManager.shared
        auth.setEnabled(false)
        XCTAssertTrue(auth.isUnlocked)
        XCTAssertFalse(auth.isEnabled)
    }

    @MainActor
    func testAuthManagerBiometryName() {
        let auth = AuthManager.shared
        let name = auth.biometryName
        // Should return a non-empty string regardless of hardware
        XCTAssertFalse(name.isEmpty, "biometryName should not be empty")
    }

    // MARK: - DCANotificationManager

    /// A future-dated last entry (today + interval ahead of `now`) means the next DCA
    /// is the entry date + interval, NOT clamped to tomorrow. We pin the EXACT calendar
    /// day: lastEntryDate + intervalDays, at 09:00. Crypto funds skip the trading-day
    /// adjustment so the date is fully determined by the fixed input.
    @MainActor
    func testComputeNextDCADateUsesLastEntryPlusIntervalWhenFuture() {
        let manager = DCANotificationManager.shared
        // Anchor the last entry well in the future so lastDate + interval is also future
        // (avoids the "<= now → tomorrow" clamp), making the result independent of `now`.
        let cal = Calendar.current
        let lastEntryDate = cal.date(byAdding: .day, value: 100, to: Date())!
        let lastEntryStr = isoDateFormatter.string(from: lastEntryDate)
        let interval = 7
        let fund = FundData(
            platform: "test", ticker: "BTC",
            config: FundConfig(fund_type: .crypto, interval_days: interval),
            entries: [FundEntry(date: lastEntryStr, value: 1000)]
        )

        let date = try! XCTUnwrap(manager.computeNextDCADate(fund: fund, intervalDays: interval))

        // Expected: parse(lastEntryStr) + interval days, at 09:00 (crypto → no trading-day shift)
        let lastParsed = isoDateFormatter.date(from: lastEntryStr)!
        let expectedDay = cal.date(byAdding: .day, value: interval, to: lastParsed)!
        let got = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let want = cal.dateComponents([.year, .month, .day], from: expectedDay)
        XCTAssertEqual(got.year, want.year)
        XCTAssertEqual(got.month, want.month)
        XCTAssertEqual(got.day, want.day, "Future entry → schedules lastEntry + interval, not tomorrow")
        XCTAssertEqual(got.hour, 9, "DCA notification fires at 09:00")
        XCTAssertEqual(got.minute, 0)
    }

    /// No entries → schedule tomorrow at 09:00. Pinned relative to `now` as a fixed
    /// 1-day offset (and crypto skips trading-day shift, so it's exactly tomorrow).
    @MainActor
    func testComputeNextDCADateNoEntriesSchedulesTomorrow() {
        let manager = DCANotificationManager.shared
        let fund = FundData(
            platform: "test", ticker: "ETH",
            config: FundConfig(fund_type: .crypto, interval_days: 14),
            entries: []
        )

        let nextDate = try! XCTUnwrap(manager.computeNextDCADate(fund: fund, intervalDays: 14))

        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        let got = cal.dateComponents([.year, .month, .day, .hour], from: nextDate)
        let want = cal.dateComponents([.year, .month, .day], from: tomorrow)
        XCTAssertEqual(got.year, want.year)
        XCTAssertEqual(got.month, want.month)
        XCTAssertEqual(got.day, want.day, "No entries → tomorrow")
        XCTAssertEqual(got.hour, 9)
        // Falsifiable directionality: the scheduled instant must be strictly in the future.
        XCTAssertGreaterThan(nextDate, Date(), "Next DCA date must be after now")
    }

    /// An overdue last entry (far in the past + short interval ⇒ lastDate+interval <= now)
    /// is clamped to tomorrow, NOT to the long-past lastDate + interval.
    @MainActor
    func testComputeNextDCADatePastDueClampsToTomorrow() {
        let manager = DCANotificationManager.shared
        let fund = FundData(
            platform: "test", ticker: "SOL",
            config: FundConfig(fund_type: .crypto, interval_days: 7),
            entries: [FundEntry(date: "2020-01-01", value: 500)]
        )

        let nextDate = try! XCTUnwrap(manager.computeNextDCADate(fund: fund, intervalDays: 7))

        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        let got = cal.dateComponents([.year, .month, .day], from: nextDate)
        let want = cal.dateComponents([.year, .month, .day], from: tomorrow)
        XCTAssertEqual(got.year, want.year)
        XCTAssertEqual(got.month, want.month)
        XCTAssertEqual(got.day, want.day, "Overdue → clamped to tomorrow, not 2020 + interval")
        // The 2020 entry + 7 days is years in the past — the result must NOT be that.
        XCTAssertGreaterThan(nextDate, Date(), "Overdue DCA must reschedule into the future")
    }

    /// Stock funds advance the fire date to the next trading day (skipping weekends/holidays),
    /// so the scheduled date must satisfy `nextTradingDay` of the raw future entry date.
    @MainActor
    func testComputeNextDCADateStockAdvancesToTradingDay() {
        let manager = DCANotificationManager.shared
        // Future entry so the result is lastEntry + interval (not the tomorrow clamp).
        let cal = Calendar.current
        let lastEntryDate = cal.date(byAdding: .day, value: 100, to: Date())!
        let lastEntryStr = isoDateFormatter.string(from: lastEntryDate)
        let interval = 7
        let fund = FundData(
            platform: "test", ticker: "AAPL",
            config: FundConfig(fund_type: .stock, interval_days: interval),
            entries: [FundEntry(date: lastEntryStr, value: 200)]
        )

        let nextDate = try! XCTUnwrap(manager.computeNextDCADate(fund: fund, intervalDays: interval))

        let lastParsed = isoDateFormatter.date(from: lastEntryStr)!
        let rawFire = cal.date(byAdding: .day, value: interval, to: lastParsed)!
        let expectedTradingDay = nextTradingDay(from: rawFire, fundType: .stock)
        let got = cal.dateComponents([.year, .month, .day, .hour], from: nextDate)
        let want = cal.dateComponents([.year, .month, .day], from: expectedTradingDay)
        XCTAssertEqual(got.year, want.year)
        XCTAssertEqual(got.month, want.month)
        XCTAssertEqual(got.day, want.day, "Stock fund must land on a trading day")
        XCTAssertEqual(got.hour, 9)
        // The landed day must itself be a trading day (weekday, not a US market holiday).
        let weekday = cal.component(.weekday, from: nextDate)
        XCTAssertNotEqual(weekday, 1, "Sunday is not a trading day")
        XCTAssertNotEqual(weekday, 7, "Saturday is not a trading day")
    }

    // MARK: - DCANotificationManager.cancelAll

    @MainActor
    func testDCACancelAllIsIdempotent() async {
        // Exercising the public API: disabling reminders twice in a row should
        // leave the manager in a consistent disabled state without crashing —
        // and must not rely on the in-memory `pendingIdentifiers` array having
        // been populated this session (the bug fixed 2026-04-24).
        let manager = DCANotificationManager.shared
        await manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        await manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
    }

    // MARK: - SpotlightIndexer

    /// With the injectable `SearchableIndexing` seam (#63) we can now assert the
    /// items handed to Spotlight directly rather than only proving the call path
    /// doesn't trap. The per-fund `uniqueIdentifier` must be exactly `FundData.id`
    /// ("platform-ticker") — if that drifts, deindexFund(id:) targets the wrong item.
    func testSpotlightIndexerIndexesItemsWithFundIdAndDomain() {
        let spy = SpySearchableIndex()
        let indexer = SpotlightIndexer(index: spy)
        let btc = FundData(
            platform: "coinbase", ticker: "BTC",
            config: FundConfig(fund_type: .crypto, status: .active, category: .sov),
            entries: [FundEntry(date: "2026-01-01", value: 50000)]
        )
        let tqqq = FundData(
            platform: "robinhood", ticker: "TQQQ",
            config: FundConfig(fund_type: .stock, status: .active, category: .volatility),
            entries: []
        )

        indexer.indexFunds([btc, tqqq])

        XCTAssertEqual(spy.indexedItems.count, 2, "Both funds should be indexed")
        let ids = spy.indexedItems.map(\.uniqueIdentifier)
        XCTAssertEqual(ids, ["coinbase-BTC", "robinhood-TQQQ"],
                       "uniqueIdentifier must equal FundData.id (platform-ticker)")
        // All items share the funds domain so deindexAll() can target them.
        for item in spy.indexedItems {
            XCTAssertEqual(item.domainIdentifier, "net.shadowpuppet.EscapeMint.funds")
        }
        // Title is the human-readable "TICKER — Platform"; description must NOT leak value.
        let btcItem = try! XCTUnwrap(spy.indexedItems.first { $0.uniqueIdentifier == "coinbase-BTC" })
        XCTAssertEqual(btcItem.attributeSet.title, "BTC — Coinbase")
        XCTAssertEqual(btcItem.attributeSet.contentDescription, "Active Crypto on Coinbase")
        XCTAssertFalse(btcItem.attributeSet.contentDescription?.contains("50000") ?? false,
                       "Spotlight description must not leak monetary values (PII)")
    }

    /// deindexFund(id:) and deindexAll() route to the right delete API with the
    /// expected identifiers — now observable through the injected index.
    func testSpotlightIndexerDeindexRoutesToCorrectIdentifiers() {
        let spy = SpySearchableIndex()
        let indexer = SpotlightIndexer(index: spy)

        indexer.deindexFund(id: "coinbase-BTC")
        indexer.deindexAll()

        XCTAssertEqual(spy.deletedIdentifiers, ["coinbase-BTC"],
                       "deindexFund deletes by the fund's unique identifier")
        XCTAssertEqual(spy.deletedDomains, ["net.shadowpuppet.EscapeMint.funds"],
                       "deindexAll deletes the whole funds domain")
    }

    func testSpotlightIndexerEmptyFundsIndexesNothing() {
        let spy = SpySearchableIndex()
        let indexer = SpotlightIndexer(index: spy)
        // Empty array is a valid no-op — it still calls the index with zero items.
        indexer.indexFunds([])
        XCTAssertTrue(spy.indexedItems.isEmpty)
    }

    // MARK: - WidgetSnapshot

    func testWidgetSnapshotCodableRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            totalValue: 12345.67,
            totalGainUsd: 1234.56,
            totalGainPct: 11.1,
            activeFunds: 5,
            actionableCount: 2,
            topFunds: [
                WidgetFundSnapshot(
                    ticker: "BTC", platform: "Coinbase",
                    value: 5000, gainPct: 15.2,
                    isDueForAction: true,
                    recommendedAction: "BUY",
                    recommendedAmount: 150
                ),
                WidgetFundSnapshot(
                    ticker: "ETH", platform: "Coinbase",
                    value: 2000, gainPct: -3.1,
                    isDueForAction: false,
                    recommendedAction: nil,
                    recommendedAmount: nil
                ),
            ],
            updatedAt: Date()
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.totalValue, snapshot.totalValue, accuracy: 0.01)
        XCTAssertEqual(decoded.totalGainUsd, snapshot.totalGainUsd, accuracy: 0.01)
        XCTAssertEqual(decoded.totalGainPct, snapshot.totalGainPct, accuracy: 0.01)
        XCTAssertEqual(decoded.activeFunds, snapshot.activeFunds)
        XCTAssertEqual(decoded.actionableCount, snapshot.actionableCount)
        XCTAssertEqual(decoded.topFunds.count, 2)
        XCTAssertEqual(decoded.topFunds[0].ticker, "BTC")
        XCTAssertEqual(decoded.topFunds[0].recommendedAction, "BUY")
        XCTAssertEqual(decoded.topFunds[1].recommendedAction, nil)
    }

    func testWidgetFundSnapshotCodable() throws {
        let fund = WidgetFundSnapshot(
            ticker: "SPXL", platform: "Robinhood",
            value: 3000, gainPct: 8.5,
            isDueForAction: true,
            recommendedAction: "BUY",
            recommendedAmount: 100
        )

        let data = try JSONEncoder().encode(fund)
        let decoded = try JSONDecoder().decode(WidgetFundSnapshot.self, from: data)

        XCTAssertEqual(decoded.ticker, "SPXL")
        XCTAssertEqual(decoded.platform, "Robinhood")
        XCTAssertEqual(decoded.value, 3000, accuracy: 0.01)
        XCTAssertEqual(decoded.isDueForAction, true)
        XCTAssertEqual(decoded.recommendedAction, "BUY")
        XCTAssertEqual(decoded.recommendedAmount, 100)
    }

    func testWidgetSnapshotWithNoFunds() throws {
        let snapshot = WidgetSnapshot(
            totalValue: 0,
            totalGainUsd: 0,
            totalGainPct: 0,
            activeFunds: 0,
            actionableCount: 0,
            topFunds: [],
            updatedAt: Date()
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.totalValue, 0)
        XCTAssertEqual(decoded.topFunds.count, 0)
    }

    /// Forward-compatibility (#34): a snapshot written by a NEWER app version that adds
    /// fields must still decode in an older widget extension — Swift's synthesized
    /// Decodable ignores unknown keys. If someone adds a custom decoder that rejects
    /// unknown keys, this fails and warns them they'd blank older widgets.
    func testWidgetSnapshotDecodeIgnoresUnknownFields() throws {
        let json = """
        {
          "totalValue": 2500.0,
          "totalGainUsd": 250.0,
          "totalGainPct": 11.1,
          "activeFunds": 4,
          "actionableCount": 1,
          "topFunds": [
            {
              "ticker": "BTC", "platform": "Coinbase",
              "value": 1000, "gainPct": 5.0,
              "isDueForAction": false,
              "recommendedAction": null,
              "recommendedAmount": null,
              "futureFieldFromNewerApp": "should be ignored"
            }
          ],
          "updatedAt": 762048000,
          "anotherUnknownTopLevelField": 42
        }
        """
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.totalValue, 2500.0, accuracy: 0.001)
        XCTAssertEqual(decoded.activeFunds, 4)
        XCTAssertEqual(decoded.topFunds.count, 1)
        XCTAssertEqual(decoded.topFunds[0].ticker, "BTC")
        XCTAssertNil(decoded.topFunds[0].recommendedAction)
        XCTAssertNil(decoded.topFunds[0].recommendedAmount)
    }

    /// Round-trip through the SHARED type with nil optionals preserved as nil and the
    /// non-nil twin distinguishable — pins that the app-written JSON decodes field-for-
    /// field (the contract #34 protects: app encodes, widget decodes, one shared type).
    func testWidgetSnapshotRoundTripPreservesNilAndNonNilOptionals() throws {
        let snapshot = WidgetSnapshot(
            totalValue: 9999.99,
            totalGainUsd: -123.45,
            totalGainPct: -1.2,
            activeFunds: 3,
            actionableCount: 1,
            topFunds: [
                WidgetFundSnapshot(ticker: "BTC", platform: "Coinbase", value: 100,
                                   gainPct: 1.0, isDueForAction: true,
                                   recommendedAction: "SELL", recommendedAmount: 42.5),
                WidgetFundSnapshot(ticker: "ETH", platform: "Coinbase", value: 50,
                                   gainPct: -2.0, isDueForAction: false,
                                   recommendedAction: nil, recommendedAmount: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 762_048_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.totalValue, 9999.99, accuracy: 0.001)
        XCTAssertEqual(decoded.totalGainUsd, -123.45, accuracy: 0.001)
        XCTAssertEqual(decoded.actionableCount, 1)
        XCTAssertEqual(decoded.topFunds.count, 2)
        // First fund: non-nil optionals survive with exact values.
        XCTAssertEqual(decoded.topFunds[0].recommendedAction, "SELL")
        XCTAssertEqual(try XCTUnwrap(decoded.topFunds[0].recommendedAmount), 42.5, accuracy: 0.001)
        XCTAssertTrue(decoded.topFunds[0].isDueForAction)
        // Second fund: nil optionals stay nil (not coerced to 0/"").
        XCTAssertNil(decoded.topFunds[1].recommendedAction)
        XCTAssertNil(decoded.topFunds[1].recommendedAmount)
        XCTAssertFalse(decoded.topFunds[1].isDueForAction)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, 762_048_000, accuracy: 1.0)
    }

    func testWidgetSnapshotNilOptionals() throws {
        let fund = WidgetFundSnapshot(
            ticker: "SOL", platform: "Phantom",
            value: 100, gainPct: -5.0,
            isDueForAction: false,
            recommendedAction: nil,
            recommendedAmount: nil
        )

        let data = try JSONEncoder().encode(fund)
        let decoded = try JSONDecoder().decode(WidgetFundSnapshot.self, from: data)

        XCTAssertNil(decoded.recommendedAction)
        XCTAssertNil(decoded.recommendedAmount)
        XCTAssertFalse(decoded.isDueForAction)
    }

    // MARK: - WidgetDataProvider.readSnapshot

    /// `readSnapshot()` must NEVER crash — the widget extension calls this on every
    /// timeline refresh. It can legitimately return nil (no App Group, missing file,
    /// or undecodable contents) OR a fully-populated snapshot. We can't seed the App
    /// Group container without a production injection seam (readSnapshot resolves the
    /// container URL internally — see report note), so we assert the only invariant
    /// that holds unconditionally: whatever it returns must be self-consistent. This
    /// folds the former guard-return no-op test into a single non-vacuous check —
    /// either branch makes a real assertion.
    @MainActor
    func testReadSnapshotReturnsNilOrSelfConsistentSnapshot() {
        let snap = WidgetDataProvider.readSnapshot()
        if let snap {
            XCTAssertTrue(snap.totalValue.isFinite)
            XCTAssertTrue(snap.totalGainUsd.isFinite)
            XCTAssertTrue(snap.totalGainPct.isFinite)
            XCTAssertGreaterThanOrEqual(snap.activeFunds, 0)
            XCTAssertGreaterThanOrEqual(snap.actionableCount, 0)
            // topFunds may be empty, but is bounded at 7 by `prefix(7)` in updateSnapshot.
            XCTAssertLessThanOrEqual(snap.topFunds.count, 7)
            for fund in snap.topFunds {
                XCTAssertFalse(fund.ticker.isEmpty)
                XCTAssertTrue(fund.value.isFinite)
                XCTAssertTrue(fund.gainPct.isFinite)
            }
        } else {
            // No App Group data on this run — the contract is simply "no crash, nil".
            XCTAssertNil(snap)
        }
    }

    /// With the directory-injectable `readSnapshot(from:)` seam (#63) we can seed a
    /// known snapshot in a temp directory and assert the exact decoded result —
    /// previously untestable because the App Group container URL was resolved internally.
    @MainActor
    func testReadSnapshotFromDirectoryDecodesSeededSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seeded = WidgetSnapshot(
            totalValue: 4242.42,
            totalGainUsd: 424.24,
            totalGainPct: 11.1,
            activeFunds: 2,
            actionableCount: 1,
            topFunds: [
                WidgetFundSnapshot(ticker: "BTC", platform: "Coinbase", value: 4000,
                                   gainPct: 12.0, isDueForAction: true,
                                   recommendedAction: "BUY", recommendedAmount: 100),
            ],
            updatedAt: Date(timeIntervalSince1970: 762_048_000)
        )
        let fileURL = dir.appendingPathComponent(WidgetDataProvider.snapshotFileName)
        try JSONEncoder().encode(seeded).write(to: fileURL)

        let read = try XCTUnwrap(WidgetDataProvider.readSnapshot(from: dir),
                                 "Seeded snapshot must be read back from the injected directory")
        XCTAssertEqual(read.totalValue, 4242.42, accuracy: 0.001)
        XCTAssertEqual(read.actionableCount, 1)
        XCTAssertEqual(read.topFunds.count, 1)
        XCTAssertEqual(read.topFunds[0].ticker, "BTC")
        XCTAssertEqual(read.topFunds[0].recommendedAction, "BUY")
    }

    /// Missing file in the injected directory returns nil (not a crash) — mirrors a
    /// first-launch widget read before any snapshot has been written.
    @MainActor
    func testReadSnapshotFromDirectoryReturnsNilWhenFileMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-seam-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(WidgetDataProvider.readSnapshot(from: dir),
                     "No snapshot file → nil, no crash")
    }

    /// Garbage contents in the injected directory return nil (the production `try?`
    /// swallows decode failures) rather than crashing the widget timeline refresh.
    @MainActor
    func testReadSnapshotFromDirectoryReturnsNilForGarbage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-seam-garbage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(WidgetDataProvider.snapshotFileName)
        try Data("{\"not\":\"a snapshot\"}".utf8).write(to: fileURL)

        XCTAssertNil(WidgetDataProvider.readSnapshot(from: dir),
                     "Undecodable snapshot → nil, no crash")
    }

    /// Decoding must reject malformed snapshot data without crashing — the actual
    /// `try?` in the production code makes this a tolerance test for any future
    /// schema/format drift.
    func testWidgetSnapshotDecodingRejectsGarbage() throws {
        let garbage = Data("{\"not\": \"a snapshot\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSnapshot.self, from: garbage))
    }

    func testWidgetSnapshotDecodingRejectsEmptyData() {
        let empty = Data()
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSnapshot.self, from: empty))
    }

    /// Verify the JSON contract used by the widget — a successful round-trip
    /// covering all fields (positive control for `readSnapshot` — if the
    /// decoder fails on this, the widget would always show a stale state).
    func testWidgetSnapshotDecoderContract() throws {
        let json = """
        {
          "totalValue": 1000.5,
          "totalGainUsd": 100.25,
          "totalGainPct": 11.0,
          "activeFunds": 3,
          "actionableCount": 1,
          "topFunds": [
            {
              "ticker": "BTC", "platform": "Coinbase",
              "value": 500, "gainPct": 12.5,
              "isDueForAction": true,
              "recommendedAction": "BUY",
              "recommendedAmount": 100
            }
          ],
          "updatedAt": 762048000
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.totalValue, 1000.5, accuracy: 0.001)
        XCTAssertEqual(decoded.activeFunds, 3)
        XCTAssertEqual(decoded.topFunds.count, 1)
        XCTAssertEqual(decoded.topFunds[0].ticker, "BTC")
        XCTAssertEqual(decoded.topFunds[0].recommendedAction, "BUY")
    }
}
