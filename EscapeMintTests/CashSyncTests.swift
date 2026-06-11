import XCTest
@testable import EscapeMint

/// Tests for `buildCashSyncEntry` (#37) — the pure core that mirrors a trade on a
/// `manage_cash=false` fund into a DEPOSIT/WITHDRAW on the platform's shared cash fund.
/// A bug here silently corrupts a user's cash balance, so each branch is pinned.
final class CashSyncTests: XCTestCase {

    /// A platform cash fund with a known prior balance. id is "<platform>-cash".
    private func cashFund(platform: String, balance: Double, fundSize: Double = 0) -> FundData {
        FundData(
            platform: platform, ticker: "cash",
            config: FundConfig(fund_type: .cash, manage_cash: true),
            entries: [FundEntry(date: "2025-01-01", value: balance, cash: balance, fund_size: fundSize)]
        )
    }

    private func tradingConfig() -> FundConfig {
        var c = FundConfig(fund_type: .stock, status: .active)
        c.manage_cash = false
        return c
    }

    // MARK: - BUY → WITHDRAW

    func testBuyProducesWithdrawOnCashFundWithCorrectAmount() throws {
        let cash = cashFund(platform: "robinhood", balance: 1000, fundSize: 1000)
        let buy = FundEntry(date: "2025-02-01", value: 500, action: .BUY, amount: 300)

        let result = buildCashSyncEntry(
            fundId: "robinhood-tqqq", entry: buy,
            config: tradingConfig(), cashFund: cash
        )

        let (cashFundId, cashEntry) = try unwrapSuccess(result)
        XCTAssertEqual(cashFundId, "robinhood-cash")
        XCTAssertEqual(cashEntry.action, .WITHDRAW, "A BUY draws cash out of the pool")
        XCTAssertEqual(try XCTUnwrap(cashEntry.amount), 300, accuracy: 0.001)
        // New balance = prior 1000 - 300 = 700, reflected in both value and cash.
        XCTAssertEqual(cashEntry.value, 700, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cashEntry.cash), 700, accuracy: 0.001)
        XCTAssertEqual(cashEntry.date, "2025-02-01", "Cash entry is dated to the trade")
    }

    // MARK: - SELL → DEPOSIT

    func testSellProducesDepositOnCashFundWithCorrectAmount() throws {
        let cash = cashFund(platform: "robinhood", balance: 1000)
        let sell = FundEntry(date: "2025-03-01", value: 200, action: .SELL, amount: 250)

        let result = buildCashSyncEntry(
            fundId: "robinhood-tqqq", entry: sell,
            config: tradingConfig(), cashFund: cash
        )

        let (cashFundId, cashEntry) = try unwrapSuccess(result)
        XCTAssertEqual(cashFundId, "robinhood-cash")
        XCTAssertEqual(cashEntry.action, .DEPOSIT, "A SELL returns cash to the pool")
        XCTAssertEqual(try XCTUnwrap(cashEntry.amount), 250, accuracy: 0.001)
        // New balance = prior 1000 + 250 = 1250.
        XCTAssertEqual(cashEntry.value, 1250, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cashEntry.cash), 1250, accuracy: 0.001)
    }

    // MARK: - HOLD / non-trade → skip

    func testHoldProducesNoCashEntry() {
        let cash = cashFund(platform: "robinhood", balance: 1000)
        let hold = FundEntry(date: "2025-02-01", value: 500, action: .HOLD, amount: 0)

        let result = buildCashSyncEntry(
            fundId: "robinhood-tqqq", entry: hold,
            config: tradingConfig(), cashFund: cash
        )

        switch result {
        case .success:
            XCTFail("HOLD must not produce a cash-sync entry")
        case .failure(let skip):
            guard case .notATrade = skip else {
                return XCTFail("Expected .notATrade, got \(skip)")
            }
        }
    }

    // MARK: - Fund manages own cash → skip

    func testManageCashTrueProducesNoCashEntry() {
        let cash = cashFund(platform: "robinhood", balance: 1000)
        var config = FundConfig(fund_type: .stock)
        config.manage_cash = true  // fund holds its own cash → no sync
        let buy = FundEntry(date: "2025-02-01", value: 500, action: .BUY, amount: 300)

        let result = buildCashSyncEntry(
            fundId: "robinhood-tqqq", entry: buy, config: config, cashFund: cash
        )

        switch result {
        case .success:
            XCTFail("manage_cash=true must not produce a cash-sync entry")
        case .failure(let skip):
            guard case .managesOwnCash = skip else {
                return XCTFail("Expected .managesOwnCash, got \(skip)")
            }
        }
    }

    // MARK: - No cash fund on platform → skip

    func testNoCashFundOnPlatformProducesSkipWithExpectedId() {
        let buy = FundEntry(date: "2025-02-01", value: 500, action: .BUY, amount: 300)

        let result = buildCashSyncEntry(
            fundId: "robinhood-tqqq", entry: buy,
            config: tradingConfig(), cashFund: nil
        )

        switch result {
        case .success:
            XCTFail("Missing cash fund must not produce an entry")
        case .failure(let skip):
            guard case .noCashFund(let id) = skip else {
                return XCTFail("Expected .noCashFund, got \(skip)")
            }
            XCTAssertEqual(id, "robinhood-cash", "Skip reason carries the expected cash fund id")
        }
    }

    /// A cash fund whose id doesn't match "<platform>-cash" is treated as absent.
    func testMismatchedCashFundIdIsTreatedAsMissing() {
        let wrongCash = cashFund(platform: "coinbase", balance: 1000) // id = coinbase-cash
        let buy = FundEntry(date: "2025-02-01", value: 500, action: .BUY, amount: 300)

        let result = buildCashSyncEntry(
            fundId: "robinhood-tqqq", entry: buy,
            config: tradingConfig(), cashFund: wrongCash
        )

        switch result {
        case .success:
            XCTFail("A cash fund from another platform must not be used")
        case .failure(let skip):
            guard case .noCashFund(let id) = skip else {
                return XCTFail("Expected .noCashFund, got \(skip)")
            }
            XCTAssertEqual(id, "robinhood-cash")
        }
    }

    // MARK: - Platform-prefix extraction

    func testPlatformPrefixExtractedFromMultiSegmentFundId() throws {
        // fundId with extra hyphens — platform is the FIRST segment only.
        let cash = cashFund(platform: "schwab", balance: 500)
        let buy = FundEntry(date: "2025-02-01", value: 100, action: .BUY, amount: 50)

        let result = buildCashSyncEntry(
            fundId: "schwab-brk-b", entry: buy,
            config: tradingConfig(), cashFund: cash
        )

        let (cashFundId, cashEntry) = try unwrapSuccess(result)
        XCTAssertEqual(cashFundId, "schwab-cash", "Platform = first hyphen-delimited segment")
        // Ticker note uses everything after "schwab-", uppercased: "BRK-B".
        XCTAssertEqual(cashEntry.value, 450, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cashEntry.notes).contains("BRK-B"), true,
                       "Auto note names the trading ticker")
    }

    // MARK: - Helper

    private func unwrapSuccess(
        _ result: Result<(fundId: String, entry: FundEntry), CashSyncSkip>
    ) throws -> (String, FundEntry) {
        switch result {
        case .success(let pair):
            return (pair.fundId, pair.entry)
        case .failure(let skip):
            throw XCTSkip("expected success but got skip: \(skip)")
        }
    }
}
