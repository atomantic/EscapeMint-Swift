import XCTest
@testable import EscapeMint

/// Tests for `recommendationForLiveEquity` (#38) — the pure core that produces a DCA
/// recommendation from a user-reported live equity, used by the guided Add-Entry wizard
/// before the action is recorded.
///
/// For a self-cash fund, available cash is derived as `deposits − cost basis` (see
/// `computeCashAvailableWithInterest`), so each fixture funds the pool with a DEPOSIT
/// entry and consumes part of it with a BUY. `cash_apy` is 0 to keep amounts exact
/// (no interest drift).
final class LiveRecommendationTests: XCTestCase {

    private func selfCashConfig() -> FundConfig {
        var c = FundConfig(
            fund_type: .stock, status: .active,
            target_apy: 0.10, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.25, min_profit_usd: 100,
            cash_apy: 0, manage_cash: true, accumulate: true
        )
        c.manage_cash = true
        return c
    }

    /// Deposit `deposit`, then buy `buy` → available cash = deposit − buy.
    private func selfCashFund(deposit: Double, buy: Double, marginAvailable: Double? = nil) -> FundData {
        let config = selfCashConfig()
        let buyEntry = FundEntry(date: "2025-01-02", value: buy, action: .BUY,
                                 amount: buy, shares: 5, margin_available: marginAvailable)
        let entries = [
            FundEntry(date: "2025-01-01", value: 0, action: .DEPOSIT, amount: deposit),
            buyEntry,
        ]
        return FundData(platform: "robinhood", ticker: "tqqq", config: config, entries: entries)
    }

    // MARK: - Basic BUY for a self-cash fund

    func testBasicStockFundReturnsBuyForLiveEquity() throws {
        // Deposit 1100, buy 1000 → 100 available. On-track equity → min DCA (100).
        let fund = selfCashFund(deposit: 1100, buy: 1000)
        let rec = try XCTUnwrap(
            recommendationForLiveEquity(fund: fund, currentEquity: 1020, externalCashAvailable: nil)
        )
        XCTAssertEqual(rec.action, .BUY, "On-track stock fund with cash should recommend a BUY")
        XCTAssertEqual(rec.amount, 100, accuracy: 0.001, "min DCA, fully covered by 100 available cash")
    }

    func testNoCashInSelfCashFundReturnsHold() throws {
        // Deposit exactly equals the buy → 0 cash available.
        let fund = selfCashFund(deposit: 1000, buy: 1000)
        let rec = try XCTUnwrap(
            recommendationForLiveEquity(fund: fund, currentEquity: 1020, externalCashAvailable: nil)
        )
        XCTAssertEqual(rec.action, .HOLD, "No cash → HOLD, not BUY")
        XCTAssertEqual(rec.amount, 0, accuracy: 0.001)
    }

    // MARK: - manage_cash=false resolves cash from external pool

    private func externalCashFund() -> FundData {
        var config = FundConfig(
            fund_type: .stock, status: .active,
            target_apy: 0.10, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.25, min_profit_usd: 100,
            cash_apy: 0, accumulate: true
        )
        config.manage_cash = false
        return FundData(
            platform: "robinhood", ticker: "tqqq", config: config,
            entries: [FundEntry(date: "2025-01-01", value: 500, action: .BUY, amount: 500, shares: 5)]
        )
    }

    func testManageCashFalseUsesExternalCashAvailable() throws {
        let fund = externalCashFund()
        // External pool (40) smaller than the DCA limit (100) → amount is capped at 40.
        let rec = try XCTUnwrap(
            recommendationForLiveEquity(fund: fund, currentEquity: 520, externalCashAvailable: 40)
        )
        XCTAssertEqual(rec.action, .BUY)
        XCTAssertEqual(rec.amount, 40, accuracy: 0.001,
                       "BUY amount is capped by the external cash pool, not in-fund cash")
    }

    func testManageCashFalseWithZeroExternalCashReturnsHold() throws {
        let fund = externalCashFund()
        let rec = try XCTUnwrap(
            recommendationForLiveEquity(fund: fund, currentEquity: 520, externalCashAvailable: 0)
        )
        XCTAssertEqual(rec.action, .HOLD, "No external cash → HOLD")
    }

    // MARK: - Margin headroom adds to available cash

    func testMarginEnabledAddsMarginHeadroomToAvailableCash() throws {
        // Deposit 1030, buy 1000 → 30 in-fund cash. margin_available 500 on the latest
        // entry lifts headroom to 530 ≥ limit (100), so the BUY is NOT capped at 30.
        var fund = selfCashFund(deposit: 1030, buy: 1000, marginAvailable: 500)
        fund.config.margin_enabled = true

        let rec = try XCTUnwrap(
            recommendationForLiveEquity(fund: fund, currentEquity: 1020, externalCashAvailable: nil)
        )
        XCTAssertEqual(rec.action, .BUY)
        XCTAssertEqual(rec.amount, 100, accuracy: 0.001,
                       "Margin headroom lifts available cash above the DCA limit")
    }

    /// Control: WITHOUT margin, the same 30-cash fund caps the BUY at 30 — proving the
    /// previous test's 100 result is specifically due to margin headroom.
    func testWithoutMarginLowCashCapsBuyAmount() throws {
        var fund = selfCashFund(deposit: 1030, buy: 1000, marginAvailable: 500)
        fund.config.margin_enabled = false

        let rec = try XCTUnwrap(
            recommendationForLiveEquity(fund: fund, currentEquity: 1020, externalCashAvailable: nil)
        )
        XCTAssertEqual(rec.action, .BUY)
        XCTAssertEqual(rec.amount, 30, accuracy: 0.001,
                       "Without margin, the BUY is capped at the 30 in-fund cash")
    }
}
