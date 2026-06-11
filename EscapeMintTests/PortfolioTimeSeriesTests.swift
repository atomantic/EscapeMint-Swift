import XCTest
@testable import EscapeMint

/// Tests for `computePortfolioTimeSeries` / `FundMetricsCursor` (#35).
///
/// The cursor carries cost-basis accumulation, full-liquidation resets, cash TWAB, and
/// per-date aggregation. Values below are hand-computed from the fixed fund datasets;
/// each assertion fails under a broken cursor (e.g. a liquidation that doesn't reset
/// cost basis, or a cash balance read from the wrong column).
final class PortfolioTimeSeriesTests: XCTestCase {

    private func stockConfig() -> FundConfig {
        FundConfig(
            fund_type: .stock, status: .active,
            target_apy: 0.10, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.25, min_profit_usd: 100,
            cash_apy: 0.04, manage_cash: true, accumulate: true
        )
    }

    private func point(_ series: [PortfolioTimeSeriesPoint], on date: String) -> PortfolioTimeSeriesPoint? {
        series.first { $0.date == date }
    }

    // MARK: - Full liquidation then rebuy (single fund)

    func testFullLiquidationThenRebuySingleFund() throws {
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 10, fund_size: 1000),
            // Full liquidation: sell entire 10-share position for 1300 → realized +300.
            FundEntry(date: "2024-06-01", value: 0, action: .SELL, amount: 1300, shares: 10, fund_size: 0),
            // Rebuy a fresh position.
            FundEntry(date: "2024-07-01", value: 500, action: .BUY, amount: 500, shares: 5, fund_size: 500),
            // Held position now worth 600.
            FundEntry(date: "2024-08-01", value: 600, action: .HOLD, fund_size: 500),
        ]
        let fund = FundData(platform: "robinhood", ticker: "tqqq", config: stockConfig(), entries: entries)
        let series = computePortfolioTimeSeries([fund])

        // All four entry dates are sampled (well under the 60-point cap).
        XCTAssertEqual(series.count, 4)

        // At the liquidation date: position fully closed, realized gain captured.
        let liq = try XCTUnwrap(point(series, on: "2024-06-01"))
        XCTAssertEqual(liq.totalValue, 0, accuracy: 0.01, "Full liquidation → no live value")
        XCTAssertEqual(liq.realized, 300, accuracy: 0.01, "Sold 1300 against 1000 basis → +300")
        XCTAssertEqual(liq.unrealized, 0, accuracy: 0.01, "Cost basis reset to 0 after liquidation")

        // At the final HOLD: rebought basis 500, value 600 → unrealized +100; realized stays 300.
        let end = try XCTUnwrap(point(series, on: "2024-08-01"))
        XCTAssertEqual(end.totalValue, 600, accuracy: 0.01)
        XCTAssertEqual(end.realized, 300, accuracy: 0.01, "Realized gain persists across the rebuy")
        XCTAssertEqual(end.unrealized, 100, accuracy: 0.01, "600 value − 500 rebuy basis")
        XCTAssertEqual(end.liquid, 400, accuracy: 0.01, "liquid = realized 300 + unrealized 100")
        XCTAssertEqual(end.cashBalance, 0, accuracy: 0.01, "No cash fund in this portfolio")

        // Total gain is positive → liquid APY must be positive (falsifiable vs a sign bug).
        XCTAssertGreaterThan(end.liquidAPY, 0, "Positive total gain → positive liquid APY")
        XCTAssertTrue(end.liquidAPY.isFinite)
    }

    // MARK: - Multi-fund aggregate (stock + cash)

    func testMultiFundAggregateStockPlusCash() throws {
        let stockEntries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 10, fund_size: 1000),
            FundEntry(date: "2024-06-01", value: 0, action: .SELL, amount: 1300, shares: 10, fund_size: 0),
            FundEntry(date: "2024-07-01", value: 500, action: .BUY, amount: 500, shares: 5, fund_size: 500),
            FundEntry(date: "2024-08-01", value: 600, action: .HOLD, fund_size: 500),
        ]
        let stock = FundData(platform: "robinhood", ticker: "tqqq", config: stockConfig(), entries: stockEntries)

        let cashConfig = FundConfig(fund_type: .cash, status: .active, cash_apy: 0.04, manage_cash: true)
        let cashEntries = [
            FundEntry(date: "2024-01-01", value: 5000, cash: 5000, action: .DEPOSIT, amount: 5000, fund_size: 5000),
            FundEntry(date: "2024-08-01", value: 5050, cash: 5050, action: .INTEREST, cash_interest: 50, fund_size: 5000),
        ]
        let cash = FundData(platform: "robinhood", ticker: "cash", config: cashConfig, entries: cashEntries)

        let series = computePortfolioTimeSeries([stock, cash])
        // Union of dates: 01-01, 06-01, 07-01, 08-01.
        XCTAssertEqual(series.count, 4)

        let end = try XCTUnwrap(point(series, on: "2024-08-01"))
        // totalValue = stock 600 + cash 5050.
        XCTAssertEqual(end.totalValue, 5650, accuracy: 0.01)
        // cashBalance is the cash fund only.
        XCTAssertEqual(end.cashBalance, 5050, accuracy: 0.01)
        // assetValue = total − cash.
        XCTAssertEqual(end.assetValue, 600, accuracy: 0.01)
        // realized = stock 300 + cash interest 50.
        XCTAssertEqual(end.realized, 350, accuracy: 0.01)
        // unrealized = stock 100 + cash 0.
        XCTAssertEqual(end.unrealized, 100, accuracy: 0.01)

        // At an intermediate date the cash cursor only sees its first (deposit) entry.
        let mid = try XCTUnwrap(point(series, on: "2024-06-01"))
        XCTAssertEqual(mid.cashBalance, 5000, accuracy: 0.01, "Cash interest not yet credited at 06-01")
        // Stock fully liquidated at 06-01 → only cash contributes value.
        XCTAssertEqual(mid.totalValue, 5000, accuracy: 0.01)
    }

    // MARK: - Closed funds excluded

    func testClosedFundsExcludedFromSeries() {
        var closedConfig = stockConfig()
        closedConfig.status = .closed
        let closed = FundData(
            platform: "robinhood", ticker: "dead", config: closedConfig,
            entries: [FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 10)]
        )
        // A portfolio of only closed funds yields an empty series.
        let series = computePortfolioTimeSeries([closed])
        XCTAssertTrue(series.isEmpty, "All-closed portfolio → no time series points")
    }

    func testEmptyPortfolioYieldsEmptySeries() {
        XCTAssertTrue(computePortfolioTimeSeries([]).isEmpty)
    }
}
