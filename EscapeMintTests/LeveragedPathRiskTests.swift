import XCTest
@testable import EscapeMint

final class LeveragedPathRiskTests: XCTestCase {

    private func resourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EscapeMint/Resources/\(name)")
    }

    private func loadWeekly(_ name: String) throws -> HistoricalData {
        let url = resourceURL(name)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(HistoricalData.self, from: data)
    }

    private func stockConfig() -> FundConfig {
        FundConfig(
            fund_type: .stock, status: .active,
            target_apy: 0.10, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.25, min_profit_usd: 100,
            manage_cash: true, margin_enabled: false, accumulate: true
        )
    }

    private func buyState(gainPct: Double, cash: Double = 5000) -> FundState {
        let cost = 1000.0
        let value = cost * (1 + gainPct)
        return FundState(
            cashAvailableUsd: cash,
            expectedTargetUsd: 500,
            actualValueUsd: value,
            startInputUsd: cost,
            gainUsd: value - cost,
            gainPct: gainPct,
            targetDiffUsd: value - 500,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )
    }

    // MARK: - Defaults stay off

    func testLegacyFundConfigLeavesFallbackOff() throws {
        let json = #"{"fund_type":"stock","status":"active","__ticker":"tqqq","margin_enabled":false}"#
        let config = try JSONDecoder().decode(FundConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.fallback_enabled)
        XCTAssertFalse(config.fallbackEnabled)
        XCTAssertEqual(config.fallbackDrawdownThreshold, 0.60, accuracy: 0.0001)
        XCTAssertEqual(config.fallbackMADays, 200)
        let encoded = try JSONEncoder().encode(config)
        let again = try JSONDecoder().decode(FundConfig.self, from: encoded)
        XCTAssertNil(again.fallback_enabled)
        XCTAssertFalse(again.fallbackEnabled)
    }

    func testDisabledFallbackDoesNotChangeTheBuy() {
        var config = stockConfig()
        config.fallback_enabled = false
        let state = buyState(gainPct: -0.80)
        let plain = computeRecommendation(config: config, state: state)
        let routed = computeRecommendation(
            config: config,
            state: state,
            fallback: FallbackContext(
                routeTicker: "QQQ",
                leveragedPrices: [100, 20],
                underlyingCloses: [100, 50],
                movingAverageBars: 2,
                costBasisDrawdown: 0.80
            )
        )
        XCTAssertEqual(plain?.action, .BUY)
        XCTAssertEqual(routed?.action, .BUY)
        XCTAssertEqual(plain?.amount ?? -1, routed?.amount ?? -2, accuracy: 0.001)
        XCTAssertNil(routed?.routeTicker)
        XCTAssertEqual(plain?.reasoning, routed?.reasoning)
        XCTAssertEqual(routed?.amount ?? 0, 200, accuracy: 0.01)
    }

    func testEnabledFallbackRoutesTheSameDollarsToTheOneXFund() {
        var config = stockConfig()
        config.fallback_enabled = true
        config.fallback_ticker = "qqq"
        config.fallback_drawdown = 0.60
        config.fallback_ma_days = 200
        let state = buyState(gainPct: -0.10)
        let underlying = Array(repeating: 100.0, count: 200) + [70.0]
        let leveraged = Array(repeating: 100.0, count: underlying.count)
        let rec = computeRecommendation(
            config: config,
            state: state,
            fallback: FallbackContext(
                routeTicker: "QQQ",
                leveragedPrices: leveraged,
                underlyingCloses: underlying,
                movingAverageBars: 200,
                costBasisDrawdown: 0
            )
        )
        XCTAssertEqual(rec?.action, .BUY)
        XCTAssertEqual(rec?.amount ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(rec?.routeTicker, "QQQ")
        XCTAssertTrue(rec?.reasoning.contains("QQQ") == true)
        XCTAssertTrue(rec?.reasoning.contains("margin") == true)
    }

    func testFallbackDoesNotRedirectASell() {
        var config = stockConfig()
        config.fallback_enabled = true
        config.min_profit_usd = 10
        config.target_apy = 0.01
        let state = FundState(
            cashAvailableUsd: 5000,
            expectedTargetUsd: 100,
            actualValueUsd: 2000,
            startInputUsd: 1000,
            gainUsd: 1000,
            gainPct: 1,
            targetDiffUsd: 1900,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )
        let rec = computeRecommendation(
            config: config,
            state: state,
            fallback: FallbackContext(
                routeTicker: "QQQ",
                leveragedPrices: [100, 10],
                underlyingCloses: [100, 10],
                movingAverageBars: 2,
                costBasisDrawdown: 0.9
            )
        )
        XCTAssertEqual(rec?.action, .SELL)
        XCTAssertNil(rec?.routeTicker)
    }

    func testScaledBuyLimitMatchesComputeLimit() {
        let samples: [(Double, Double, Double)] = [
            (0, 0, 0),
            (1000, 50, 0.05),
            (1000, -100, -0.10),
            (1000, -400, -0.40),
        ]
        for sample in samples {
            let config = FundConfig(
                fund_type: .stock,
                input_min_usd: 100, input_mid_usd: 200, input_max_usd: 400,
                max_at_pct: -0.25
            )
            let state = FundState(
                actualValueUsd: sample.0 + sample.1,
                startInputUsd: sample.0,
                gainUsd: sample.1,
                gainPct: sample.2
            )
            XCTAssertEqual(
                scaledBuyLimit(
                    costBasis: sample.0, gain: sample.1, gainPct: sample.2,
                    minBuy: 100, midBuy: 200, maxBuy: 400, maxAtLoss: -0.25
                ),
                computeLimit(config: config, state: state),
                accuracy: 0.0001
            )
        }
    }

    // MARK: - Route

    func testMovingAverageBarsConvertWeeklySamples() {
        XCTAssertEqual(fallbackMovingAverageBars(days: 200, cadence: .daily), 200)
        XCTAssertEqual(fallbackMovingAverageBars(days: 200, cadence: .weekly), 40)
        XCTAssertEqual(fallbackMovingAverageBars(days: 0, cadence: .weekly), 1)
    }

    func testPythonOrdinalMatchesKnownDates() {
        XCTAssertEqual(pythonDateOrdinal("1999-03-10"), 729823)
        XCTAssertEqual(pythonDateOrdinal("2000-02-29"), 730179)
        XCTAssertEqual(pythonDateOrdinal("2012-12-31"), 734868)
    }

    func testRouteFollowsTheMovingAverageAndResetsWhenTheTrendRecovers() {
        let dip = Array(repeating: 100.0, count: 200) + Array(repeating: 70.0, count: 30) + Array(repeating: 130.0, count: 80)
        let flat = Array(repeating: 100.0, count: dip.count)
        let points = fallbackRoutePoints(
            rule: FallbackRule(enabled: true, drawdownThreshold: 0.60, movingAverageBars: 200),
            leveragedPrices: flat,
            underlyingCloses: dip
        )
        XCTAssertEqual(points.count, dip.count)
        let dipRoutes = points.enumerated().filter { dip[$0.offset] == 70 }.map(\.element.route)
        XCTAssertFalse(dipRoutes.isEmpty)
        XCTAssertTrue(dipRoutes.allSatisfy { $0 == .underlying })
        XCTAssertEqual(points.last?.route, .leveraged)
    }

    func testDeepDrawdownRoutesToTheOneXFundWhileTheTrendIsStillUp() {
        let underlying = (0..<250).map { 100.0 + Double($0) }
        var leveraged = Array(repeating: 100.0, count: 249)
        leveraged.append(30)
        let rule = FallbackRule(enabled: true, drawdownThreshold: 0.60, movingAverageBars: 200)
        let points = fallbackRoutePoints(rule: rule, leveragedPrices: leveraged, underlyingCloses: underlying)
        XCTAssertEqual(points[points.count - 2].route, .leveraged)
        XCTAssertEqual(points.last?.route, .underlying)
        XCTAssertGreaterThan(points.last?.drawdown ?? 0, 0.60)

        var looser = rule
        looser.drawdownThreshold = 0.80
        let held = fallbackRoutePoints(rule: looser, leveragedPrices: leveraged, underlyingCloses: underlying)
        XCTAssertEqual(held.last?.route, .leveraged)

        var off = rule
        off.enabled = false
        let unchanged = fallbackRoutePoints(rule: off, leveragedPrices: leveraged, underlyingCloses: underlying)
        XCTAssertTrue(unchanged.allSatisfy { $0.route == .leveraged })
    }

    func testSuggestedPairs() {
        XCTAssertEqual(LeveragedPairs.suggestedUnderlying(for: "TQQQ"), "qqq")
        XCTAssertEqual(LeveragedPairs.suggestedUnderlying(for: "soxl"), "soxx")
        XCTAssertEqual(LeveragedPairs.suggestedUnderlying(for: "SPXL"), "spy")
        XCTAssertNil(LeveragedPairs.suggestedUnderlying(for: "VTI"))
    }

    // MARK: - Wipeout

    func testSingleDayCrashApproximatelyWipesTheThreeXFund() {
        let thirtyThree = syntheticLeveragedPrices(underlying: [100, 67])
        XCTAssertEqual(thirtyThree.count, 2)
        let remaining = thirtyThree[1] / thirtyThree[0]
        XCTAssertLessThan(remaining, 0.02, "A 33% index day should leave about \(remaining) of the 3x fund")
        XCTAssertGreaterThan(remaining, 0)

        let oneThird = syntheticLeveragedPrices(underlying: [100, 100 * (1 - 1.0 / 3.0), 140])
        XCTAssertEqual(oneThird[1], 0, accuracy: 1e-9)
        XCTAssertEqual(oneThird[2], 0, accuracy: 1e-9, "A wiped fund does not resurrect")
    }

    // MARK: - 1999–2012

    func testBundledWeeklyPairsMatchTheExistingGrid() throws {
        let vti = try loadWeekly("vti-weekly.json")
        for name in ["qqq-weekly.json", "soxx-weekly.json", "soxl-weekly.json"] {
            let series = try loadWeekly(name)
            XCTAssertEqual(series.prices.count, 261, name)
            XCTAssertEqual(series.dataPoints, series.prices.count, name)
            XCTAssertEqual(series.prices.first?.date, vti.prices.first?.date, name)
            XCTAssertEqual(series.prices.last?.date, vti.prices.last?.date, name)
            XCTAssertEqual(series.startDate, "2021-01-27", name)
            XCTAssertEqual(series.endDate, "2026-01-21", name)
            XCTAssertTrue(series.source?.contains("Yahoo Finance") == true, name)
            XCTAssertGreaterThan(series.prices.first?.value ?? 0, 0, name)
            let dates = series.prices.map(\.date)
            XCTAssertEqual(dates, vti.prices.map(\.date), name)
        }
        XCTAssertNil(vti.source)
        XCTAssertEqual(try loadWeekly("qqq-weekly.json").ticker, "QQQ")
        XCTAssertEqual(try loadWeekly("soxx-weekly.json").ticker, "SOXX")
        XCTAssertEqual(try loadWeekly("soxl-weekly.json").ticker, "SOXL")
    }

    func testQQQWeeklySeriesRunsInTheBacktest() throws {
        let qqq = try loadWeekly("qqq-weekly.json")
        var config = BacktestConfig()
        config.spxlPct = 0
        config.vtiPct = 0
        config.brgnxPct = 0
        config.tqqqPct = 0
        config.btcPct = 0
        config.gldPct = 0
        config.slvPct = 0
        config.soxxPct = 0
        config.soxlPct = 0
        config.qqqPct = 1
        let result = runBacktest(config: config, historicalData: ["QQQ": qqq])
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result?.finalValue ?? 0, 0)
        XCTAssertGreaterThan(result?.totalBuys ?? 0, 0)
    }

    func testNasdaqAndSemiconductorPathsPreserveMoreWithTheFallback() throws {
        let library = try XCTUnwrap(loadPathRiskLibrary(from: resourceURL("path-risk-daily.json")))
        XCTAssertTrue(library.source.contains("Yahoo Finance"))
        XCTAssertEqual(library.assumptions.leverage, 3, accuracy: 0.0001)
        XCTAssertEqual(library.assumptions.annualExpense, 0.009, accuracy: 0.0000001)
        XCTAssertEqual(library.assumptions.drawdownThreshold, 0.60, accuracy: 0.0001)
        XCTAssertEqual(library.assumptions.movingAverageBars, 200)
        XCTAssertEqual(library.assumptions.initialCash, 10_000, accuracy: 0.01)
        XCTAssertEqual(library.assumptions.weeklyDeposit, 400, accuracy: 0.01)

        let nasdaq = try XCTUnwrap(library.scenarios.first { $0.id == "nasdaq-1999-2012" })
        let semis = try XCTUnwrap(library.scenarios.first { $0.id == "semiconductor-1999-2012" })
        let nasdaqResult = try XCTUnwrap(compareLeveragedPath(bars: nasdaq.bars, assumptions: library.assumptions))
        let semiResult = try XCTUnwrap(compareLeveragedPath(bars: semis.bars, assumptions: library.assumptions))

        assertScenario("Nasdaq-100 1999-2012", nasdaqResult, finalMultiple: 1.0, troughMultiple: 2.0, benchmarkBeatsFallback: false)
        assertScenario("Semiconductors 1999-2012", semiResult, finalMultiple: 1.5, troughMultiple: 2.0, benchmarkBeatsFallback: true)
    }

    func testIntroExplainsWipeoutRiskAndTheFallback() {
        XCTAssertEqual(introSteps.count, 14)
        let step = introSteps.first { $0.title == "3x Funds Can Be Wiped Out" }
        XCTAssertNotNil(step)
        XCTAssertEqual(step?.chartType, .pathRisk)
        let text = step?.content.map { item -> String in
            switch item {
            case .text(let value), .warning(let value), .quote(let value), .bullet(let value), .crossBullet(let value):
                return value
            case .boldLabel(let label, _, let value):
                return label + " " + value
            case .link(let value, let label):
                return value + label
            }
        }.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("volatility") || text.localizedCaseInsensitiveContains("decay") || text.contains("not symmetric"))
        XCTAssertTrue(text.contains("33%"))
        XCTAssertTrue(text.contains("QQQ"))
        XCTAssertTrue(text.contains("margin"))
        XCTAssertTrue(text.contains("VTI"))
    }

    private func assertScenario(
        _ name: String,
        _ comparison: PathComparison,
        finalMultiple: Double,
        troughMultiple: Double,
        benchmarkBeatsFallback: Bool
    ) {
        let leveraged = comparison.leveragedOnly
        let fallback = comparison.fallback
        let benchmark = comparison.benchmark
        let report = """
        \(name)
        instrument max drawdown \(comparison.instrumentMaxDrawdown)
        3x-only final \(leveraged.finalValue) irr \(leveraged.annualizedIRR) maxDD \(leveraged.maxDrawdown) min \(leveraged.minimumValue) bought \(leveraged.totalBought) cashMin \(leveraged.minimumCash)
        fallback final \(fallback.finalValue) irr \(fallback.annualizedIRR) maxDD \(fallback.maxDrawdown) min \(fallback.minimumValue) levBuys \(fallback.leveragedBuys) oneXBuys \(fallback.underlyingBuys) bought \(fallback.totalBought) cashMin \(fallback.minimumCash)
        VTI final \(benchmark.finalValue) irr \(benchmark.annualizedIRR) maxDD \(benchmark.maxDrawdown) min \(benchmark.minimumValue) bought \(benchmark.totalBought) cashMin \(benchmark.minimumCash)
        """
        print(report)

        XCTAssertGreaterThan(comparison.instrumentMaxDrawdown, 0.99, report)
        XCTAssertGreaterThan(fallback.finalValue, leveraged.finalValue * finalMultiple, report)
        XCTAssertGreaterThan(fallback.minimumValue, leveraged.minimumValue * troughMultiple, report)
        XCTAssertGreaterThan(fallback.leveragedBuys, 0, report)
        XCTAssertGreaterThan(fallback.underlyingBuys, 0, report)
        XCTAssertEqual(fallback.totalBought, leveraged.totalBought, accuracy: 0.05, report)
        XCTAssertEqual(benchmark.totalBought, leveraged.totalBought, accuracy: 0.05, report)
        XCTAssertGreaterThanOrEqual(leveraged.minimumCash, -0.01, report)
        XCTAssertGreaterThanOrEqual(fallback.minimumCash, -0.01, report)
        XCTAssertGreaterThanOrEqual(benchmark.minimumCash, -0.01, report)
        XCTAssertLessThan(benchmark.maxDrawdown, 0.60, report)
        XCTAssertLessThan(benchmark.maxDrawdown, leveraged.maxDrawdown - 0.25, report)
        XCTAssertGreaterThan(benchmark.finalValue, leveraged.finalValue, report)
        if benchmarkBeatsFallback {
            XCTAssertGreaterThan(benchmark.finalValue, fallback.finalValue, report)
        }
        XCTAssertTrue(leveraged.annualizedIRR.isFinite, report)
        XCTAssertTrue(fallback.annualizedIRR.isFinite, report)
        XCTAssertTrue(benchmark.annualizedIRR.isFinite, report)
        XCTAssertGreaterThan(fallback.annualizedIRR, leveraged.annualizedIRR, report)
    }
}
