import XCTest
@testable import EscapeMint

/// Tests for ViewCache — verifies cache key stability, type-safe chart caching,
/// per-fund invalidation, and memory-pressure clearing. ViewCache is a
/// `@MainActor` singleton, so all tests run on the main actor.
@MainActor
final class ViewCacheTests: XCTestCase {

    private var cache: ViewCache { ViewCache.shared }

    override func setUp() async throws {
        try await super.setUp()
        // ViewCache is a singleton — clear non-essential caches between tests so prior
        // runs don't leak state. The historical-data cache is intentionally preserved
        // because reloading the JSON bundle on every test would be wasteful.
        cache.clearNonEssentialCaches()
    }

    override func tearDown() async throws {
        cache.clearNonEssentialCaches()
        try await super.tearDown()
    }

    // MARK: - Cache Keys

    func testFundCacheKeyIncorporatesEntryCount() {
        let k1 = cache.fundCacheKey("coinbase-btc", entryCount: 10)
        let k2 = cache.fundCacheKey("coinbase-btc", entryCount: 11)
        XCTAssertNotEqual(k1, k2, "Different entry counts must produce different keys")
    }

    func testFundCacheKeyIsStable() {
        let k1 = cache.fundCacheKey("coinbase-btc", entryCount: 10)
        let k2 = cache.fundCacheKey("coinbase-btc", entryCount: 10)
        XCTAssertEqual(k1, k2)
    }

    // MARK: - Row Cache

    func testCachedRowsRoundTrip() {
        let rows = [makeRow()]
        cache.cacheRows(rows, fundId: "coinbase-btc", entryCount: 5)
        let fetched = cache.cachedRows(fundId: "coinbase-btc", entryCount: 5)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.count, 1)
        XCTAssertEqual(fetched?[0].extracted, 0)
    }

    func testCachedRowsReturnsNilForUnseenKey() {
        XCTAssertNil(cache.cachedRows(fundId: "never-stored", entryCount: 0))
    }

    func testCachedRowsKeyedByEntryCount() {
        // Storing rows under count=5 must not be readable under count=6 — that's how
        // the caller invalidates after appending an entry.
        cache.cacheRows([makeRow()], fundId: "coinbase-btc", entryCount: 5)
        XCTAssertNotNil(cache.cachedRows(fundId: "coinbase-btc", entryCount: 5))
        XCTAssertNil(cache.cachedRows(fundId: "coinbase-btc", entryCount: 6))
    }

    // MARK: - Chart Points Cache (type-safe)

    func testChartPointsRoundTripPerType() {
        let valuePoints = [makeValuePoint(date: "2025-01-01", value: 1000)]
        let plPoints = [makePLPoint(date: "2025-01-01", liquid: 100)]

        cache.cacheChartPoints(valuePoints, type: ValuePoint.self,
                               fundId: "coinbase-btc", entryCount: 3)
        cache.cacheChartPoints(plPoints, type: PLPoint.self,
                               fundId: "coinbase-btc", entryCount: 3)

        let v = cache.cachedChartPoints(type: ValuePoint.self,
                                        fundId: "coinbase-btc", entryCount: 3)
        let p = cache.cachedChartPoints(type: PLPoint.self,
                                        fundId: "coinbase-btc", entryCount: 3)

        XCTAssertEqual(v?.count, 1)
        XCTAssertEqual(p?.count, 1)
        XCTAssertEqual(v?[0].value, 1000)
        XCTAssertEqual(p?[0].liquid, 100)
    }

    /// Different chart types under the same fund/entryCount must NOT collide.
    /// Without this guarantee the type-erased Any storage would be a footgun.
    func testChartPointsTypeNamespaceIsolation() {
        let value = [makeValuePoint(date: "2025-01-01", value: 1)]
        cache.cacheChartPoints(value, type: ValuePoint.self,
                               fundId: "coinbase-btc", entryCount: 7)
        // Reading as a different type returns nil, never a misinterpreted blob.
        let cross = cache.cachedChartPoints(type: PLPoint.self,
                                            fundId: "coinbase-btc", entryCount: 7)
        XCTAssertNil(cross)
    }

    // MARK: - Per-Fund Invalidation

    func testInvalidateFundCacheClearsAllArtifactsForFund() {
        // Prime three caches for fund A
        cache.cacheRows([makeRow()], fundId: "fund-a", entryCount: 3)
        cache.cacheChartPoints([makeValuePoint(date: "2025-01-01", value: 100)],
                               type: ValuePoint.self, fundId: "fund-a", entryCount: 3)
        cache.cacheChartPoints([makePLPoint(date: "2025-01-01", liquid: 1)],
                               type: PLPoint.self, fundId: "fund-a", entryCount: 3)
        // And one for fund B
        cache.cacheRows([makeRow()], fundId: "fund-b", entryCount: 4)

        cache.invalidateFundCache(fundId: "fund-a")

        // Fund A is gone in all three caches
        XCTAssertNil(cache.cachedRows(fundId: "fund-a", entryCount: 3))
        XCTAssertNil(cache.cachedChartPoints(type: ValuePoint.self,
                                             fundId: "fund-a", entryCount: 3))
        XCTAssertNil(cache.cachedChartPoints(type: PLPoint.self,
                                             fundId: "fund-a", entryCount: 3))
        // Fund B is untouched
        XCTAssertNotNil(cache.cachedRows(fundId: "fund-b", entryCount: 4),
                        "Invalidating one fund must not clear other funds' caches")
    }

    // MARK: - Memory Pressure Clearing

    func testClearNonEssentialCachesEmptiesEverything() {
        cache.cacheRows([makeRow()], fundId: "fund-a", entryCount: 3)
        cache.cacheChartPoints([makeValuePoint(date: "2025-01-01", value: 100)],
                               type: ValuePoint.self, fundId: "fund-a", entryCount: 3)
        cache.cacheDerivPoints([], fundId: "fund-a", entryCount: 3)

        cache.clearNonEssentialCaches()

        XCTAssertNil(cache.cachedRows(fundId: "fund-a", entryCount: 3))
        XCTAssertNil(cache.cachedChartPoints(type: ValuePoint.self,
                                             fundId: "fund-a", entryCount: 3))
        XCTAssertNil(cache.cachedDerivPoints(fundId: "fund-a", entryCount: 3))
    }

    // MARK: - Derivatives Points Cache

    func testDerivPointsNilStorageRemovesEntry() {
        // Caching `nil` should evict any existing entry — the production code uses
        // this to clear stale derivatives points when a fund is reclassified.
        cache.cacheDerivPoints([makeDerivPoint()], fundId: "fund-a", entryCount: 2)
        XCTAssertNotNil(cache.cachedDerivPoints(fundId: "fund-a", entryCount: 2))

        cache.cacheDerivPoints(nil, fundId: "fund-a", entryCount: 2)
        XCTAssertNil(cache.cachedDerivPoints(fundId: "fund-a", entryCount: 2))
    }

    // MARK: - Backtest State

    func testUpdateBacktestPresetUpdatesObservableState() {
        cache.updateBacktestPreset(.tqqq)
        XCTAssertEqual(cache.backtestPreset, .tqqq)

        cache.updateBacktestPreset(.btc)
        XCTAssertEqual(cache.backtestPreset, .btc)
    }

    func testUpdateBacktestSortOrderUpdatesObservableState() {
        cache.updateBacktestSortOrder(.asc)
        XCTAssertEqual(cache.backtestSortOrder, .asc)

        cache.updateBacktestSortOrder(.desc)
        XCTAssertEqual(cache.backtestSortOrder, .desc)
    }

    func testUpdateBacktestConfigPersists() {
        var config = BacktestConfig()
        config.btcPct = 1.0
        config.initialCash = 12345
        cache.updateBacktestConfig(config)
        XCTAssertEqual(cache.backtestConfig.btcPct, 1.0)
        XCTAssertEqual(cache.backtestConfig.initialCash, 12345)
    }

    func testUpdateBacktestDateRangeNilable() {
        let r = BacktestDateRange(start: "2024-01-01", end: "2024-12-31")
        cache.updateBacktestDateRange(r)
        XCTAssertEqual(cache.backtestDateRange?.start, "2024-01-01")

        cache.updateBacktestDateRange(nil)
        XCTAssertNil(cache.backtestDateRange)
    }

    // MARK: - Helpers

    private func makeRow() -> ComputedEntryRow {
        ComputedEntryRow(
            extracted: 0,
            realized: 0,
            liquidPnl: 0,
            realizedApy: 0,
            liquidApy: 0,
            isClosingEntry: false,
            invested: 0,
            unrealized: 0,
            sumShares: 0,
            sumExtracted: 0,
            sumExpenses: 0,
            sumCashInterest: 0,
            sumDividends: 0
        )
    }

    private func makeValuePoint(date: String, value: Double) -> ValuePoint {
        ValuePoint(id: date, date: date, value: value, invested: 0, target: 0)
    }

    private func makePLPoint(date: String, liquid: Double) -> PLPoint {
        PLPoint(id: date, date: date, realized: 0, liquid: liquid)
    }

    private func makeDerivPoint() -> DerivativesChartPoint {
        DerivativesChartPoint(
            id: "2025-01-01",
            date: "2025-01-01",
            costBasis: 0, positionValue: 0,
            avgEntry: 0, liqPrice: 0, position: 0,
            marginBalance: 0, marginLocked: 0, leverage: 0,
            capturedProfit: 0, liquidPL: 0,
            realizedAPY: 0, liquidAPY: 0,
            sumRealized: 0, sumFunding: 0, sumInterest: 0,
            sumRebates: 0, sumFees: 0
        )
    }
}
