import XCTest
@testable import EscapeMint

/// Tests the pure phrasing logic behind the Siri Shortcuts / App Intents.
/// The intents themselves are thin wrappers around PortfolioVoiceSummary, so
/// exercising the phrasing here covers the value-bearing behavior without the
/// AppIntents framework or a live store.
final class AppIntentsTests: XCTestCase {

    private func snapshot(
        totalValue: Double = 10_000,
        totalGainUsd: Double = 1_500,
        totalGainPct: Double = 17.6,
        activeFunds: Int = 3,
        actionableCount: Int = 0,
        topFunds: [WidgetFundSnapshot] = []
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            totalValue: totalValue,
            totalGainUsd: totalGainUsd,
            totalGainPct: totalGainPct,
            activeFunds: activeFunds,
            actionableCount: actionableCount,
            topFunds: topFunds,
            updatedAt: Date()
        )
    }

    private func fund(
        _ ticker: String,
        platform: String = "Coinbase",
        value: Double,
        gainPct: Double,
        due: Bool = false,
        action: String? = nil,
        amount: Double? = nil
    ) -> WidgetFundSnapshot {
        WidgetFundSnapshot(
            ticker: ticker,
            platform: platform,
            value: value,
            gainPct: gainPct,
            isDueForAction: due,
            recommendedAction: action,
            recommendedAmount: amount
        )
    }

    // MARK: - Portfolio Value

    func testPortfolioValueGain() {
        let phrase = PortfolioVoiceSummary.portfolioValue(snapshot())
        XCTAssertTrue(phrase.contains("up"))
        XCTAssertTrue(phrase.contains("17.6%"))
        XCTAssertFalse(phrase.contains("down"))
    }

    func testPortfolioValueLoss() {
        let phrase = PortfolioVoiceSummary.portfolioValue(
            snapshot(totalGainUsd: -800, totalGainPct: -7.2)
        )
        XCTAssertTrue(phrase.contains("down"))
        XCTAssertTrue(phrase.contains("7.2%"))
    }

    func testPortfolioValueNoData() {
        XCTAssertEqual(
            PortfolioVoiceSummary.portfolioValue(nil),
            PortfolioVoiceSummary.noDataMessage
        )
        let empty = snapshot(totalValue: 0, totalGainUsd: 0, totalGainPct: 0, activeFunds: 0)
        XCTAssertEqual(
            PortfolioVoiceSummary.portfolioValue(empty),
            PortfolioVoiceSummary.noDataMessage
        )
    }

    // MARK: - Top Performer

    func testTopPerformerPicksHighestGainPct() {
        let funds = [
            fund("BTC", value: 5000, gainPct: 15.2),
            fund("ETH", value: 8000, gainPct: 42.0),
            fund("SOL", value: 2000, gainPct: 9.1),
        ]
        let top = PortfolioVoiceSummary.topPerformingFund(snapshot(topFunds: funds))
        XCTAssertEqual(top?.ticker, "ETH")

        let phrase = PortfolioVoiceSummary.topPerformer(snapshot(topFunds: funds))
        XCTAssertTrue(phrase.contains("ETH"))
        XCTAssertTrue(phrase.contains("+42.0%"))
    }

    func testTopPerformerTieBreaksOnValue() {
        let funds = [
            fund("AAA", value: 1000, gainPct: 10.0),
            fund("BBB", value: 9000, gainPct: 10.0),
        ]
        let top = PortfolioVoiceSummary.topPerformingFund(snapshot(topFunds: funds))
        XCTAssertEqual(top?.ticker, "BBB")
    }

    func testTopPerformerNoFunds() {
        XCTAssertEqual(
            PortfolioVoiceSummary.topPerformer(snapshot(topFunds: [])),
            PortfolioVoiceSummary.noDataMessage
        )
        XCTAssertNil(PortfolioVoiceSummary.topPerformingFund(nil))
    }

    // MARK: - Morning Summary

    func testMorningSummaryWithActionsDue() {
        let funds = [
            fund("BTC", value: 5000, gainPct: 22.0, due: true, action: "BUY", amount: 150),
        ]
        let phrase = PortfolioVoiceSummary.morningSummary(
            snapshot(actionableCount: 2, topFunds: funds)
        )
        XCTAssertTrue(phrase.hasPrefix("Good morning"))
        XCTAssertTrue(phrase.contains("2 actions are due today"))
        XCTAssertTrue(phrase.contains("BUY BTC"))
    }

    func testMorningSummarySingleActionGrammar() {
        let funds = [fund("BTC", value: 5000, gainPct: 5.0, due: true, action: "BUY")]
        let phrase = PortfolioVoiceSummary.morningSummary(
            snapshot(actionableCount: 1, topFunds: funds)
        )
        XCTAssertTrue(phrase.contains("1 action is due today"))
    }

    func testMorningSummaryNoActionsDue() {
        let phrase = PortfolioVoiceSummary.morningSummary(snapshot(actionableCount: 0))
        XCTAssertTrue(phrase.contains("No DCA actions are due today"))
    }

    func testMorningSummaryNoData() {
        XCTAssertEqual(
            PortfolioVoiceSummary.morningSummary(nil),
            PortfolioVoiceSummary.noDataMessage
        )
    }
}
