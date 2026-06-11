import XCTest
@testable import EscapeMint

/// Tests for chart point computations (#36):
/// - `computeDerivativesChartData` state machine across all action branches
/// - `computeAPYPoints` / cash-APY for a single-buy fixed-gain fund
///
/// Values are hand-computed from the fixed input sequences below; substitute a broken
/// branch (e.g. drop the FUNDING credit) and the corresponding assertion fails.
final class ChartSeriesTests: XCTestCase {

    private func derivativesConfig() -> FundConfig {
        var c = FundConfig(fund_type: .derivatives, status: .active)
        c.contract_multiplier = 0.01
        c.initial_margin_rate = 0.25
        c.maintenance_margin_rate = 0.20
        return c
    }

    // MARK: - Derivatives state machine

    /// A full sequence touching every branch. We deliberately leave `cash`,
    /// `entry_price`, `unrealized_pnl`, `liquidation_price`, and `margin_locked` unset so
    /// the engine COMPUTES them (rather than echoing TSV passthrough values).
    func testDerivativesChartDataAfterFullActionSequence() throws {
        let entries: [FundEntry] = [
            FundEntry(date: "2025-01-01", value: 1000, action: .DEPOSIT, amount: 1000),
            FundEntry(date: "2025-01-02", value: 1000, action: .BUY, amount: 500,
                      price: 50, contracts: 10, fee: 2),
            FundEntry(date: "2025-01-03", value: 1000, action: .FUNDING, amount: 10),
            FundEntry(date: "2025-01-04", value: 1000, action: .INTEREST, amount: 5),
            FundEntry(date: "2025-01-05", value: 1000, action: .REBATE, amount: 3),
            FundEntry(date: "2025-01-06", value: 1000, action: .SELL, amount: 250,
                      price: 60, contracts: 4, fee: 1),
            FundEntry(date: "2025-01-07", value: 1000, action: .FEE, amount: 4),
            FundEntry(date: "2025-01-08", value: 1000, action: .WITHDRAW, amount: 100),
        ]

        let points = computeDerivativesChartData(entries: entries, config: derivativesConfig())
        XCTAssertEqual(points.count, 8, "Distinct dates, under sample cap → one point each")
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(last.date, "2025-01-08")

        // Position: bought 10, sold 4 → 6 remaining.
        XCTAssertEqual(last.position, 6, accuracy: 0.0001)
        // Realized P&L from the SELL: sold 4 contracts at avg cost 50 each (200) for 250 → +50.
        XCTAssertEqual(last.sumRealized, 50, accuracy: 0.01)
        // Captured profit = realized 50 + funding 10 + interest 5 + rebates 3 - fees 7 = 61.
        XCTAssertEqual(last.sumFunding, 10, accuracy: 0.01)
        XCTAssertEqual(last.sumInterest, 5, accuracy: 0.01)
        XCTAssertEqual(last.sumRebates, 3, accuracy: 0.01)
        XCTAssertEqual(last.sumFees, 7, accuracy: 0.01, "2 (buy) + 1 (sell) + 4 (FEE) = 7")
        XCTAssertEqual(last.capturedProfit, 61, accuracy: 0.01)
        // marginBalance walk: 1000 -2 +10 +5 +3 +50 -1 -4 -100 = 961.
        XCTAssertEqual(last.marginBalance, 961, accuracy: 0.01)
        // Cost basis = remaining buy cost = 300 (6 contracts × 50).
        XCTAssertEqual(last.costBasis, 300, accuracy: 0.01)
        // Unrealized = (lastTradePrice 60 - avgCost 50) × 6 = 60.
        // liquidPL = captured 61 + unrealized 60 = 121.
        XCTAssertEqual(last.liquidPL, 121, accuracy: 0.01)
        // Leverage = currentNotional (6 × 60 = 360) / marginLocked (6 × 50 × 0.25 = 75) = 4.8.
        XCTAssertEqual(last.leverage, 4.8, accuracy: 0.001)
        XCTAssertEqual(last.marginLocked, 75, accuracy: 0.01)
        // avgEntry = avgCostPerContract / cm = 50 / 0.01 = 5000.
        XCTAssertEqual(last.avgEntry, 5000, accuracy: 0.01)
    }

    /// The DEPOSIT-only first point must reflect just the deposit, with no realized P&L
    /// or position — isolating the DEPOSIT branch.
    func testDerivativesFirstPointIsDepositOnly() throws {
        let entries: [FundEntry] = [
            FundEntry(date: "2025-01-01", value: 1000, action: .DEPOSIT, amount: 1000),
            FundEntry(date: "2025-01-02", value: 1000, action: .BUY, amount: 500,
                      price: 50, contracts: 10, fee: 2),
        ]
        let points = computeDerivativesChartData(entries: entries, config: derivativesConfig())
        let first = try XCTUnwrap(points.first)
        XCTAssertEqual(first.date, "2025-01-01")
        XCTAssertEqual(first.marginBalance, 1000, accuracy: 0.01)
        XCTAssertEqual(first.position, 0, accuracy: 0.0001)
        XCTAssertEqual(first.sumRealized, 0, accuracy: 0.01)
        XCTAssertEqual(first.leverage, 0, accuracy: 0.001, "No position → no leverage")
    }

    // MARK: - APY points (non-cash, single buy, fixed gain)

    /// A stock fund with a single BUY and a later HOLD whose `value` reflects a gain.
    /// The APY chart points must be non-zero and positive at the gain point (falsifiable:
    /// a sign flip or zeroed gain breaks this), and the realized line stays 0 with no sells.
    func testAPYPointsForSingleBuyFixedGainFund() throws {
        var config = FundConfig(
            fund_type: .stock, status: .active,
            target_apy: 0.10, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.25, min_profit_usd: 100, cash_apy: 0.04
        )
        config.accumulate = true
        // Buy $1000 on day 0; 365 days later the position is worth $1100 (10% gain, held).
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 10),
            FundEntry(date: "2024-12-31", value: 1100, action: .HOLD),
        ]
        let points = computeAPYPoints(entries: entries, config: config)
        XCTAssertEqual(points.count, 2)

        // No sells → realized APY stays 0 across the series.
        XCTAssertEqual(points[0].realizedAPY, 0, accuracy: 0.0001)
        XCTAssertEqual(points[1].realizedAPY, 0, accuracy: 0.0001)

        // Liquid APY tracks unrealized gain. At ~1 year and +10% unrealized, it must be
        // a positive number near 0.10 (not zero, not negative).
        XCTAssertGreaterThan(points[1].liquidAPY, 0.05,
                             "A held +10% over ~1yr should yield a clearly positive liquid APY")
        XCTAssertLessThan(points[1].liquidAPY, 0.20)
    }

    /// Cash fund APY uses TWAB. A single deposit earning a year of interest yields a
    /// positive APY at the interest entry; before any interest it is 0.
    func testCashAPYPointsForFixedInterestFund() throws {
        let config = FundConfig(fund_type: .cash, status: .active, cash_apy: 0.05)
        // $10,000 balance; one year later $500 interest credited (5% simple).
        let entries = [
            FundEntry(date: "2024-01-01", value: 10000, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2024-12-31", value: 10500, cash: 10500, action: .INTEREST, cash_interest: 500),
        ]
        let points = computeAPYPoints(entries: entries, config: config)
        XCTAssertEqual(points.count, 2)
        // First entry: no interest yet → APY 0.
        XCTAssertEqual(points[0].realizedAPY, 0, accuracy: 0.0001)
        // Second entry: $500 on a ~$10k TWAB over ~365 days → positive APY near 5%.
        XCTAssertGreaterThan(points[1].realizedAPY, 0.03,
                             "A year of 5% interest must produce a clearly positive cash APY")
        XCTAssertLessThan(points[1].realizedAPY, 0.08)
        // Cash funds report the same value on realized and liquid lines.
        XCTAssertEqual(points[1].realizedAPY, points[1].liquidAPY, accuracy: 0.0001)
    }
}
