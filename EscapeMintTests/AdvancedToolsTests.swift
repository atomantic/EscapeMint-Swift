import XCTest
@testable import EscapeMint

/// Tests for recalculateFundSize and interpolateColumn (AdvancedTools.swift)
final class AdvancedToolsTests: XCTestCase {

    // MARK: - Recalculate Fund Size

    func testRecalculateFundSizeBasicBuys() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10, price: 50),
            FundEntry(date: "2025-01-08", value: 1100, action: .BUY, amount: 300, shares: 5, price: 60),
            FundEntry(date: "2025-01-15", value: 1200, action: .HOLD),
        ]

        let result = recalculateFundSize(entries: entries, config: config)

        XCTAssertEqual(result.count, 3)
        // After first BUY: fund_size = 500
        XCTAssertEqual(result[0].fund_size!, 500, accuracy: 0.01)
        // After second BUY: fund_size = 800
        XCTAssertEqual(result[1].fund_size!, 800, accuracy: 0.01)
        // HOLD: fund_size still 800
        XCTAssertEqual(result[2].fund_size!, 800, accuracy: 0.01)
    }

    func testRecalculateFundSizeWithSell() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-02-01", value: 1200, action: .SELL, amount: 200, shares: 4, price: 60),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        XCTAssertEqual(result.count, 2)
        // After BUY: fund_size = 1000
        XCTAssertEqual(result[0].fund_size!, 1000, accuracy: 0.01)
        // In accumulate mode, sell is not deducted from fund_size
        XCTAssertEqual(result[1].fund_size!, 1000, accuracy: 0.01)
    }

    func testRecalculateFundSizeFullLiquidation() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-02-01", value: 500, action: .SELL, amount: 500, shares: 20, price: 25),
            FundEntry(date: "2025-03-01", value: 0, action: .HOLD),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        XCTAssertEqual(result.count, 3)
        // Liquidation entry itself reflects state before reset (sells deducted from buys)
        XCTAssertEqual(result[1].fund_size!, 500, accuracy: 0.01)
        // After liquidation resets, next entry starts fresh at 0
        XCTAssertEqual(result[2].fund_size!, 0, accuracy: 0.01)
    }

    func testRecalculateFundSizeWithDividends() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true, dividend_reinvest: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-04-01", value: 1100, action: .HOLD, dividend: 25),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        // fund_size includes dividend reinvestment: 1000 + 25 = 1025
        XCTAssertEqual(result[1].fund_size!, 1025, accuracy: 0.01)
    }

    func testRecalculateFundSizeWithExpenses() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true, expense_from_fund: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-02-01", value: 1000, expense: 10),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        // fund_size = 1000 - 10 = 990
        XCTAssertEqual(result[1].fund_size!, 990, accuracy: 0.01)
    }

    func testRecalculateFundSizeWithDepositsWithdrawals() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 5000, action: .DEPOSIT, amount: 5000),
            FundEntry(date: "2025-01-08", value: 5000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-02-01", value: 4000, action: .WITHDRAW, amount: 500),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        // After deposit: 5000
        XCTAssertEqual(result[0].fund_size!, 5000, accuracy: 0.01)
        // After buy: 5000 + 1000 = 6000
        XCTAssertEqual(result[1].fund_size!, 6000, accuracy: 0.01)
        // After withdrawal: 6000 - 500 = 5500
        XCTAssertEqual(result[2].fund_size!, 5500, accuracy: 0.01)
    }

    func testRecalculateRecalcsValueFromPrice() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true)
        let entries = [
            FundEntry(date: "2025-01-01", value: 0, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-01-08", value: 0, action: .HOLD, price: 55),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        // value should be recalculated: 20 shares * 50 = 1000
        XCTAssertEqual(result[0].value, 1000, accuracy: 0.01)
        // 20 shares * 55 = 1100
        XCTAssertEqual(result[1].value, 1100, accuracy: 0.01)
    }

    func testRecalculatePreservesOriginalOrder() {
        let config = FundConfig(fund_type: .stock, status: .active, accumulate: true)
        // Entries out of date order
        let entries = [
            FundEntry(date: "2025-03-01", value: 1200, action: .HOLD),
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2025-02-01", value: 1100, action: .HOLD),
        ]

        let result = recalculateFundSize(entries: entries, config: config)
        // Verify dates are back in original positions
        XCTAssertEqual(result[0].date, "2025-03-01")
        XCTAssertEqual(result[1].date, "2025-01-01")
        XCTAssertEqual(result[2].date, "2025-02-01")
    }

    func testComputeFundSizeForEntryCarriesPreviousFundSizeForBuy() {
        let config = FundConfig(fund_type: .crypto, status: .active, accumulate: false)
        let existing = [
            FundEntry(date: "2025-12-28", value: 3297.78, action: .BUY, amount: 500, fund_size: 8800),
            FundEntry(date: "2026-01-04", value: 4641.32, action: .BUY, amount: 250, fund_size: 8800),
        ]
        let newEntry = FundEntry(date: "2026-01-06", value: 4925.10, action: .BUY, amount: 250)

        let fundSize = computeFundSizeForEntry(newEntry, existingEntries: existing, config: config)

        XCTAssertEqual(fundSize, 9050, accuracy: 0.01)
    }

    func testComputeFundSizeForEntryDoesNotRebaseFromHistoricalHarvestMath() {
        let config = FundConfig(fund_type: .crypto, status: .active, accumulate: false)
        let existing = [
            FundEntry(date: "2025-01-01", value: 0, action: .BUY, amount: 6000, shares: 100, fund_size: 6000),
            FundEntry(date: "2025-08-25", value: 5181.13, action: .BUY, amount: 100, shares: 456.64, fund_size: 8000),
            FundEntry(date: "2025-12-28", value: 3297.78, action: .BUY, amount: 500, shares: 3891.09, fund_size: 8800),
        ]
        let newEntry = FundEntry(date: "2026-01-04", value: 4641.32, action: .BUY, amount: 250, shares: 1591.95)

        let fundSize = computeFundSizeForEntry(newEntry, existingEntries: existing, config: config)

        XCTAssertEqual(fundSize, 9050, accuracy: 0.01)
    }

    // MARK: - Interpolate Column

    func testInterpolateColumnBasic() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 100, fund_size: 1000),
            FundEntry(date: "2025-01-11", value: 200),  // missing fund_size
            FundEntry(date: "2025-01-21", value: 300, fund_size: 2000),
        ]

        let (result, stats) = interpolateColumn(.fund_size, entries: entries)

        XCTAssertEqual(stats.interpolated, 1)
        XCTAssertEqual(stats.knownValues, 2)
        XCTAssertEqual(stats.totalEntries, 3)
        // Midpoint between 1000 and 2000 (10 days of 20 = 50%)
        XCTAssertEqual(result[1].fund_size!, 1500, accuracy: 1.0)
    }

    func testInterpolateNoMissingValues() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 100, fund_size: 1000),
            FundEntry(date: "2025-01-08", value: 200, fund_size: 2000),
        ]

        let (result, stats) = interpolateColumn(.fund_size, entries: entries)
        XCTAssertEqual(stats.interpolated, 0)
        XCTAssertEqual(stats.knownValues, 2)
        XCTAssertEqual(result[0].fund_size, 1000)
        XCTAssertEqual(result[1].fund_size, 2000)
    }

    func testInterpolateEmptyEntries() {
        let (result, stats) = interpolateColumn(.value, entries: [])
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(stats.interpolated, 0)
        XCTAssertEqual(stats.totalEntries, 0)
        XCTAssertEqual(stats.knownValues, 0)
    }

    func testInterpolateNoKnownValues() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 100),
            FundEntry(date: "2025-01-08", value: 200),
        ]

        // margin_available is nil for all entries
        let (_, stats) = interpolateColumn(.margin_available, entries: entries)
        XCTAssertEqual(stats.interpolated, 0)
        XCTAssertEqual(stats.knownValues, 0)
    }

    func testInterpolateEdgeExtrapolation() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 100),  // no fund_size — before first known
            FundEntry(date: "2025-01-08", value: 200, fund_size: 5000),
            FundEntry(date: "2025-01-15", value: 300),  // no fund_size — after last known
        ]

        let (result, stats) = interpolateColumn(.fund_size, entries: entries)
        XCTAssertEqual(stats.interpolated, 2)
        // Before first known: extrapolate from nearest = 5000
        XCTAssertEqual(result[0].fund_size!, 5000, accuracy: 0.01)
        // After last known: extrapolate from nearest = 5000
        XCTAssertEqual(result[2].fund_size!, 5000, accuracy: 0.01)
    }

    func testInterpolateMarginBorrowed() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 100, margin_borrowed: 0),
            FundEntry(date: "2025-01-11", value: 200),  // missing margin_borrowed
            FundEntry(date: "2025-01-21", value: 300, margin_borrowed: 1000),
        ]

        let (result, stats) = interpolateColumn(.margin_borrowed, entries: entries)
        XCTAssertEqual(stats.interpolated, 1)
        // Linear interpolation: 0 + (1000 - 0) * 10/20 = 500
        XCTAssertEqual(result[1].margin_borrowed!, 500, accuracy: 1.0)
    }

    func testInterpolatePreservesOriginalOrder() {
        let entries = [
            FundEntry(date: "2025-03-01", value: 300, fund_size: 3000),
            FundEntry(date: "2025-01-01", value: 100, fund_size: 1000),
            FundEntry(date: "2025-02-01", value: 200),  // missing fund_size
        ]

        let (result, _) = interpolateColumn(.fund_size, entries: entries)
        // Dates should be in original order
        XCTAssertEqual(result[0].date, "2025-03-01")
        XCTAssertEqual(result[1].date, "2025-01-01")
        XCTAssertEqual(result[2].date, "2025-02-01")
    }

    // MARK: - InterpolatableColumn

    func testInterpolatableColumnLabels() {
        XCTAssertEqual(InterpolatableColumn.margin_available.label, "Margin Available")
        XCTAssertEqual(InterpolatableColumn.margin_borrowed.label, "Margin Borrowed")
        XCTAssertEqual(InterpolatableColumn.fund_size.label, "Fund Size")
        XCTAssertEqual(InterpolatableColumn.value.label, "Value")
    }

    func testInterpolatableColumnAllCases() {
        XCTAssertEqual(InterpolatableColumn.allCases.count, 4)
    }

    // MARK: - recalculateEntryPrices

    func testRecalculateEntryPricesBasic() {
        // amount / |shares| → price. With 2 dollar_decimals, 500/10 = 50.00.
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10),
            FundEntry(date: "2025-01-08", value: 1100, action: .BUY, amount: 600, shares: 12),
        ]

        let (result, updated) = recalculateEntryPrices(entries: entries, dollarDecimals: 2)
        XCTAssertEqual(updated, 2)
        XCTAssertEqual(result[0].price, 50.0)
        XCTAssertEqual(result[1].price, 50.0)
    }

    func testRecalculateEntryPricesUsesAbsoluteShares() {
        // Sell imports may store shares as negative, but the computed price should
        // still be positive: amount / |shares|.
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .SELL, amount: 200, shares: -4),
        ]
        let (result, updated) = recalculateEntryPrices(entries: entries, dollarDecimals: 2)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(result[0].price, 50.0)
    }

    func testRecalculateEntryPricesSkipsZeroOrMissing() {
        // Zero amount, zero shares, and nil-amount rows must NOT be touched.
        // Avoiding a divide-by-zero is the original bug guard.
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .HOLD),                                   // no amount/shares
            FundEntry(date: "2025-01-08", value: 1100, action: .BUY, amount: 0, shares: 10),             // zero amount
            FundEntry(date: "2025-01-15", value: 1200, action: .BUY, amount: 500, shares: 0),            // zero shares
            FundEntry(date: "2025-01-22", value: 1300, action: .BUY, amount: 500, shares: 10, price: 49) // pre-existing price
        ]
        let (result, updated) = recalculateEntryPrices(entries: entries, dollarDecimals: 2)
        // Only the last row should be updated (price 49 → 50).
        XCTAssertEqual(updated, 1)
        XCTAssertNil(result[0].price)
        XCTAssertNil(result[1].price)
        XCTAssertNil(result[2].price)
        XCTAssertEqual(result[3].price, 50.0)
    }

    func testRecalculateEntryPricesNoChangeWhenAlreadyCorrect() {
        // If price is already correct, `updated` should not increment.
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10, price: 50.0),
        ]
        let (result, updated) = recalculateEntryPrices(entries: entries, dollarDecimals: 2)
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(result[0].price, 50.0)
    }

    func testRecalculateEntryPricesHighDollarDecimalsForCheapCrypto() {
        // DOGE-style asset: 100 shares for $9.42 → 0.0942 (5 decimals).
        let entries = [
            FundEntry(date: "2025-01-01", value: 9.42, action: .BUY, amount: 9.42, shares: 100),
        ]
        let (result, updated) = recalculateEntryPrices(entries: entries, dollarDecimals: 5)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(result[0].price!, 0.0942, accuracy: 0.000001)
    }

    func testRecalculateEntryPricesPreservesOtherFields() {
        // Pure price recalculation must not perturb shares, amount, value, or date.
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10, dividend: 5, notes: "first"),
        ]
        let (result, _) = recalculateEntryPrices(entries: entries, dollarDecimals: 2)
        XCTAssertEqual(result[0].date, "2025-01-01")
        XCTAssertEqual(result[0].value, 1000)
        XCTAssertEqual(result[0].amount, 500)
        XCTAssertEqual(result[0].shares, 10)
        XCTAssertEqual(result[0].action, .BUY)
        XCTAssertEqual(result[0].dividend, 5)
        XCTAssertEqual(result[0].notes, "first")
    }

    func testRecalculateEntryPricesEmpty() {
        let (result, updated) = recalculateEntryPrices(entries: [], dollarDecimals: 2)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(updated, 0)
    }
}
