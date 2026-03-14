import XCTest
@testable import EscapeMint

final class EngineTests: XCTestCase {
    func testComputeStartInput() {
        let trades = [
            Trade(date: "2025-01-01", amountUsd: 500, type: .buy),
            Trade(date: "2025-01-15", amountUsd: 300, type: .buy),
        ]
        let result = computeStartInput(trades: trades, asOfDate: "2025-02-01")
        XCTAssertEqual(result, 800, accuracy: 0.01)
    }

    func testComputeRecommendationBuy() {
        var config = fundTypeDefaults[.stock]!
        config.fund_size_usd = 5000
        config.target_apy = 0.10
        config.input_min_usd = 100

        let state = FundState(
            cashAvailableUsd: 4500,
            expectedTargetUsd: 550,
            actualValueUsd: 500,
            startInputUsd: 500,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: -50,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .BUY)
    }

    func testFormatCurrency() {
        let result = formatCurrency(1234.56)
        XCTAssertTrue(result.contains("1,234"))
    }
}
