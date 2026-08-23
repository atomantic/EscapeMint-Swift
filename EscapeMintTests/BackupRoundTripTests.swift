import XCTest
@testable import EscapeMint

/// Tests for the backup JSON export→import round-trip (#39).
///
/// `exportToBackupJSON` serializes entries via a hand-built dictionary that conditionally
/// omits fields, so a silent field drop is otherwise undetectable. These tests export
/// known funds, re-import them, and assert field-by-field equality including notes and
/// every optional numeric field.
///
/// FundStore is a singleton bound to the real funds directory (no injectable dir seam —
/// see StorageTests for the same constraint), so we use a UNIQUE non-test platform per
/// run and register teardown cleanup, mirroring `testUpdateHistoryCache*`.
final class BackupRoundTripTests: XCTestCase {

    private var store: FundStore!
    private var platform: String!

    override func setUp() {
        super.setUp()
        store = FundStore.shared
        // Non-test platform (importFromBackupJSON skips test/demo platforms), unique per run.
        platform = "bkrt\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// A fund with notes and EVERY optional numeric field populated must round-trip with
    /// no field dropped or altered.
    func testFullEntryRoundTripsAllFields() async throws {
        let fundId = "\(platform!)-btc"
        addTeardownBlock { [store, fundId] in
            try? await store?.deleteFund(id: fundId)
        }

        var config = FundConfig(
            fund_type: .crypto, status: .active, category: .sov,
            target_apy: 0.15, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.30, min_profit_usd: 100,
            cash_apy: 0.05, manage_cash: true,
            accumulate: true, dividend_reinvest: true, interest_reinvest: true
        )
        config.dollar_decimals = 4

        let original = FundEntry(
            date: "2025-01-15", value: 1500.50, cash: 3000.25, action: .BUY,
            amount: 500.10, shares: 10.5, price: 142.86, dividend: 25.50,
            expense: 5.0, cash_interest: 1.25, fund_size: 5000.0,
            margin_available: 1000.0, margin_borrowed: 200.0, margin_expense: 3.5,
            notes: "round-trip with\ttab and special chars café",
            contracts: 2.0, entry_price: 100.0, liquidation_price: 50.0,
            unrealized_pnl: 123.45, margin_locked: 500.0, fee: 1.5, margin: 750.0
        )
        let fund = FundData(platform: platform, ticker: "btc", config: config, entries: [original])

        try await store.writeFund(fund)

        // Export → delete from store → re-import → read back.
        let backupURL = try await store.exportToBackupJSON()
        try await store.deleteFund(id: fundId)
        let afterDelete = await store.readFundById(fundId)
        XCTAssertNil(afterDelete, "Fund should be gone before re-import")

        let imported = try await store.importFromBackupJSON(backupURL)
        XCTAssertEqual(imported, 1, "Exactly one fund should re-import")

        let maybeReloaded = await store.readFundById(fundId)
        let reloaded = try XCTUnwrap(maybeReloaded)
        XCTAssertEqual(reloaded.entries.count, 1)
        let e = reloaded.entries[0]

        XCTAssertEqual(e.date, original.date)
        XCTAssertEqual(e.value, original.value, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.cash), 3000.25, accuracy: 0.01)
        XCTAssertEqual(e.action, .BUY)
        XCTAssertEqual(try XCTUnwrap(e.amount), 500.10, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.shares), 10.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(e.price), 142.86, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(e.dividend), 25.50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.expense), 5.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.cash_interest), 1.25, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.fund_size), 5000.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.margin_available), 1000.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.margin_borrowed), 200.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.margin_expense), 3.5, accuracy: 0.01)
        XCTAssertEqual(e.notes, original.notes, "notes (incl. tab + unicode) must survive")
        XCTAssertEqual(try XCTUnwrap(e.contracts), 2.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(e.entry_price), 100.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(e.liquidation_price), 50.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(e.unrealized_pnl), 123.45, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.margin_locked), 500.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.fee), 1.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(e.margin), 750.0, accuracy: 0.01)

        // Config fields must also survive.
        XCTAssertEqual(reloaded.config.fund_type, .crypto)
        XCTAssertEqual(reloaded.config.category, .sov)
        XCTAssertEqual(reloaded.config.target_apy, 0.15)
        XCTAssertEqual(reloaded.config.dollar_decimals, 4)
        XCTAssertEqual(reloaded.config.accumulate, true)
        XCTAssertEqual(reloaded.platform, platform)
        XCTAssertEqual(reloaded.ticker, "btc")
    }

    /// A minimal entry (only date + value) must round-trip with all optionals staying nil
    /// — not silently coerced to 0. This catches the inverse failure mode of field drops.
    func testMinimalEntryKeepsOptionalsNil() async throws {
        let fundId = "\(platform!)-eth"
        addTeardownBlock { [store, fundId] in
            try? await store?.deleteFund(id: fundId)
        }

        let config = FundConfig(fund_type: .crypto, status: .active)
        let fund = FundData(
            platform: platform, ticker: "eth", config: config,
            entries: [FundEntry(date: "2025-06-01", value: 42.0)]
        )
        try await store.writeFund(fund)

        let backupURL = try await store.exportToBackupJSON()
        try await store.deleteFund(id: fundId)
        _ = try await store.importFromBackupJSON(backupURL)

        let maybeReloaded = await store.readFundById(fundId)
        let reloaded = try XCTUnwrap(maybeReloaded)
        let e = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(e.date, "2025-06-01")
        XCTAssertEqual(e.value, 42.0, accuracy: 0.01)
        XCTAssertNil(e.cash)
        XCTAssertNil(e.action)
        XCTAssertNil(e.amount)
        XCTAssertNil(e.shares)
        XCTAssertNil(e.dividend)
        XCTAssertNil(e.notes)
        XCTAssertNil(e.margin)
    }

    /// Replace All must preflight semantic usability before touching existing funds.
    /// This forces the former "syntactically valid but every record skipped" failure
    /// mode with an unsafe ID and proves the original pair remains readable.
    func testReplaceBackupRejectsZeroUsableFundsWithoutDeletingExistingFund() async throws {
        let fund = FundData(
            platform: platform,
            ticker: "preserve",
            config: FundConfig(fund_type: .stock, status: .active),
            entries: [FundEntry(date: "2025-01-01", value: 321)]
        )
        let fundId = fund.id
        try await store.writeFund(fund)
        addTeardownBlock { [store, fundId] in
            try? await store?.deleteFund(id: fundId)
        }

        let invalidBackup = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-replace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: invalidBackup) }
        let json = #"{"version":"1.0.0","funds":[{"id":"../escape","platform":"real","ticker":"btc","config":{},"entries":[]}]}"#
        try Data(json.utf8).write(to: invalidBackup)

        do {
            _ = try await store.replaceAllFundsFromBackupJSON(invalidBackup)
            XCTFail("A replacement with no usable funds must fail before deletion")
        } catch {
            // expected
        }
        let retainedFund = await store.readFundById(fundId)
        let retained = try XCTUnwrap(retainedFund)
        XCTAssertEqual(retained.entries.last?.value, 321)
    }

    /// Multiple entries across multiple actions must all survive in order.
    func testMultiEntryOrderAndActionsRoundTrip() async throws {
        let fundId = "\(platform!)-tqqq"
        addTeardownBlock { [store, fundId] in
            try? await store?.deleteFund(id: fundId)
        }

        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10),
            FundEntry(date: "2025-01-08", value: 1100, action: .HOLD, dividend: 5.0),
            FundEntry(date: "2025-01-15", value: 900, action: .SELL, amount: 200, shares: 2),
            FundEntry(date: "2025-01-22", value: 950, action: .BUY, amount: 100, shares: 1),
        ]
        let fund = FundData(
            platform: platform, ticker: "tqqq",
            config: FundConfig(fund_type: .stock, status: .active), entries: entries
        )
        try await store.writeFund(fund)

        let backupURL = try await store.exportToBackupJSON()
        try await store.deleteFund(id: fundId)
        _ = try await store.importFromBackupJSON(backupURL)

        let maybeReloaded = await store.readFundById(fundId)
        let reloaded = try XCTUnwrap(maybeReloaded)
        let sorted = reloaded.entries.sorted { $0.date < $1.date }
        XCTAssertEqual(sorted.count, 4)
        XCTAssertEqual(sorted.map(\.action), [.BUY, .HOLD, .SELL, .BUY])
        XCTAssertEqual(sorted[0].amount, 500)
        XCTAssertEqual(try XCTUnwrap(sorted[1].dividend), 5.0, accuracy: 0.01)
        XCTAssertEqual(sorted[2].action, .SELL)
        XCTAssertEqual(sorted[2].amount, 200)
    }
}
