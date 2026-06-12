import XCTest
@testable import EscapeMint

/// Tests for BacktestCache — verifies the persistent backtest state (config, preset,
/// sort order, date range) survives navigation. BacktestCache is a `@MainActor`
/// singleton, so each test runs on the main actor.
final class BacktestCacheTests: XCTestCase {

    @MainActor
    func testUpdateBacktestPresetUpdatesObservableState() {
        let cache = BacktestCache.shared
        cache.updateBacktestPreset(.tqqq)
        XCTAssertEqual(cache.backtestPreset, .tqqq)

        cache.updateBacktestPreset(.btc)
        XCTAssertEqual(cache.backtestPreset, .btc)
    }

    @MainActor
    func testUpdateBacktestSortOrderUpdatesObservableState() {
        let cache = BacktestCache.shared
        cache.updateBacktestSortOrder(.asc)
        XCTAssertEqual(cache.backtestSortOrder, .asc)

        cache.updateBacktestSortOrder(.desc)
        XCTAssertEqual(cache.backtestSortOrder, .desc)
    }

    @MainActor
    func testUpdateBacktestConfigPersists() {
        let cache = BacktestCache.shared
        var config = BacktestConfig()
        config.btcPct = 1.0
        config.initialCash = 12345
        cache.updateBacktestConfig(config)
        XCTAssertEqual(cache.backtestConfig.btcPct, 1.0)
        XCTAssertEqual(cache.backtestConfig.initialCash, 12345)
    }

    @MainActor
    func testUpdateBacktestDateRangeNilable() {
        let cache = BacktestCache.shared
        let r = BacktestDateRange(start: "2024-01-01", end: "2024-12-31")
        cache.updateBacktestDateRange(r)
        XCTAssertEqual(cache.backtestDateRange?.start, "2024-01-01")

        cache.updateBacktestDateRange(nil)
        XCTAssertNil(cache.backtestDateRange)
    }
}
