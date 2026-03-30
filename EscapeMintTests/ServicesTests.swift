import XCTest
@testable import EscapeMint

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

    @MainActor
    func testComputeNextDCADateWithEntries() {
        let manager = DCANotificationManager.shared
        let fund = FundData(
            platform: "test", ticker: "BTC",
            config: FundConfig(fund_type: .crypto, interval_days: 7),
            entries: [FundEntry(date: "2026-03-20", value: 1000)]
        )

        let nextDate = manager.computeNextDCADate(fund: fund, intervalDays: 7)
        XCTAssertNotNil(nextDate, "Should compute a next DCA date")

        // The date should be at 9:00 AM
        if let date = nextDate {
            let hour = Calendar.current.component(.hour, from: date)
            XCTAssertEqual(hour, 9, "DCA notification should be scheduled at 9 AM")
        }
    }

    @MainActor
    func testComputeNextDCADateNoEntries() {
        let manager = DCANotificationManager.shared
        let fund = FundData(
            platform: "test", ticker: "ETH",
            config: FundConfig(fund_type: .crypto, interval_days: 14),
            entries: []
        )

        let nextDate = manager.computeNextDCADate(fund: fund, intervalDays: 14)
        XCTAssertNotNil(nextDate, "Should schedule tomorrow when no entries exist")

        if let date = nextDate {
            let hour = Calendar.current.component(.hour, from: date)
            XCTAssertEqual(hour, 9)

            // Should be tomorrow
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            let scheduled = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let expected = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
            XCTAssertEqual(scheduled.year, expected.year)
            XCTAssertEqual(scheduled.month, expected.month)
            XCTAssertEqual(scheduled.day, expected.day)
        }
    }

    @MainActor
    func testComputeNextDCADatePastDue() {
        let manager = DCANotificationManager.shared
        // Entry from 30 days ago, 7-day interval → overdue, should schedule tomorrow
        let fund = FundData(
            platform: "test", ticker: "SOL",
            config: FundConfig(fund_type: .crypto, interval_days: 7),
            entries: [FundEntry(date: "2025-01-01", value: 500)]
        )

        let nextDate = manager.computeNextDCADate(fund: fund, intervalDays: 7)
        XCTAssertNotNil(nextDate)

        if let date = nextDate {
            // Since the interval is way past, should be scheduled for tomorrow
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            let scheduled = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let expected = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
            XCTAssertEqual(scheduled.day, expected.day)
        }
    }

    @MainActor
    func testComputeNextDCADateFutureEntry() {
        let manager = DCANotificationManager.shared
        // Entry in the future (just entered today), 7 day interval
        let today = todayString()
        let fund = FundData(
            platform: "test", ticker: "AAPL",
            config: FundConfig(fund_type: .stock, interval_days: 7),
            entries: [FundEntry(date: today, value: 200)]
        )

        let nextDate = manager.computeNextDCADate(fund: fund, intervalDays: 7)
        XCTAssertNotNil(nextDate)

        if let date = nextDate {
            // Should be 7 days from today, advanced to next trading day for stocks
            let rawExpected = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
            let expected = nextTradingDay(from: rawExpected, fundType: .stock)
            let scheduledDay = Calendar.current.component(.day, from: date)
            let expectedDay = Calendar.current.component(.day, from: expected)
            XCTAssertEqual(scheduledDay, expectedDay)
        }
    }

    // MARK: - LivePriceService

    @MainActor
    func testLivePriceServiceInitialState() {
        let service = LivePriceService.shared
        XCTAssertTrue(service.prices.isEmpty, "Should start with no cached prices")
        XCTAssertFalse(service.isFetching)
        XCTAssertNil(service.lastFetched)
    }

    @MainActor
    func testLivePriceServiceCacheLookup() {
        let service = LivePriceService.shared
        // No prices cached
        XCTAssertNil(service.price(for: "BTC"))
        XCTAssertNil(service.price(for: "nonexistent"))
    }

    @MainActor
    func testLivePriceServiceUnrealizedPnLNoPrice() {
        let service = LivePriceService.shared
        let fund = FundData(
            platform: "test", ticker: "BTC",
            config: FundConfig(fund_type: .crypto),
            entries: [FundEntry(date: "2026-01-01", value: 1000, shares: 0.01, price: 50000)]
        )
        // No cached price → returns nil
        XCTAssertNil(service.unrealizedPnL(for: fund))
    }

    @MainActor
    func testLivePriceServiceUnrealizedPnLNoShares() {
        let service = LivePriceService.shared
        let fund = FundData(
            platform: "test", ticker: "XYZ",
            config: FundConfig(fund_type: .stock),
            entries: [FundEntry(date: "2026-01-01", value: 1000)]
        )
        XCTAssertNil(service.unrealizedPnL(for: fund))
    }

    // MARK: - SpotlightIndexer

    func testSpotlightIndexerDoesNotCrash() {
        let indexer = SpotlightIndexer.shared
        let funds = [
            FundData(
                platform: "coinbase", ticker: "BTC",
                config: FundConfig(fund_type: .crypto, status: .active, category: .sov),
                entries: [FundEntry(date: "2026-01-01", value: 50000)]
            ),
            FundData(
                platform: "robinhood", ticker: "TQQQ",
                config: FundConfig(fund_type: .stock, status: .active, category: .volatility),
                entries: []
            ),
        ]
        // Should not throw or crash
        indexer.indexFunds(funds)

        // Deindex should also be safe
        indexer.deindexAll()
        indexer.deindexFund(id: "coinbase-BTC")
    }

    func testSpotlightIndexerEmptyFunds() {
        let indexer = SpotlightIndexer.shared
        // Should handle empty array gracefully
        indexer.indexFunds([])
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
}
