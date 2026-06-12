import XCTest
@testable import EscapeMint

/// Tests for ChartCache — verifies cache key stability, type-safe chart caching,
/// per-fund invalidation, and memory-pressure clearing. ChartCache is a
/// `@MainActor` singleton, so each cache-touching test is isolated individually.
final class ChartCacheTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // ChartCache is a singleton — clear non-essential caches between tests so prior
        // runs don't leak state.
        await MainActor.run {
            ChartCache.shared.clearNonEssentialCaches()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            ChartCache.shared.clearNonEssentialCaches()
        }
        try await super.tearDown()
    }

    // MARK: - Cache Keys

    @MainActor
    func testFundCacheKeyIncorporatesEntryCount() {
        let cache = ChartCache.shared
        let k1 = cache.fundCacheKey("coinbase-btc", entryCount: 10)
        let k2 = cache.fundCacheKey("coinbase-btc", entryCount: 11)
        XCTAssertNotEqual(k1, k2, "Different entry counts must produce different keys")
    }

    @MainActor
    func testFundCacheKeyIsStable() {
        let cache = ChartCache.shared
        let k1 = cache.fundCacheKey("coinbase-btc", entryCount: 10)
        let k2 = cache.fundCacheKey("coinbase-btc", entryCount: 10)
        XCTAssertEqual(k1, k2)
    }

    // MARK: - Row Cache

    @MainActor
    func testCachedRowsRoundTrip() {
        let cache = ChartCache.shared
        let rows = [makeRow()]
        cache.cacheRows(rows, fundId: "coinbase-btc", entryCount: 5)
        let fetched = cache.cachedRows(fundId: "coinbase-btc", entryCount: 5)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.count, 1)
        XCTAssertEqual(fetched?[0].extracted, 0)
    }

    @MainActor
    func testCachedRowsReturnsNilForUnseenKey() {
        XCTAssertNil(ChartCache.shared.cachedRows(fundId: "never-stored", entryCount: 0))
    }

    @MainActor
    func testCachedRowsKeyedByEntryCount() {
        let cache = ChartCache.shared
        // Storing rows under count=5 must not be readable under count=6 — that's how
        // the caller invalidates after appending an entry.
        cache.cacheRows([makeRow()], fundId: "coinbase-btc", entryCount: 5)
        XCTAssertNotNil(cache.cachedRows(fundId: "coinbase-btc", entryCount: 5))
        XCTAssertNil(cache.cachedRows(fundId: "coinbase-btc", entryCount: 6))
    }

    // MARK: - Chart Points Cache (type-safe)

    @MainActor
    func testChartPointsRoundTripPerType() {
        let cache = ChartCache.shared
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
    /// Without this guarantee the typed storage would be a footgun.
    @MainActor
    func testChartPointsTypeNamespaceIsolation() {
        let cache = ChartCache.shared
        let value = [makeValuePoint(date: "2025-01-01", value: 1)]
        cache.cacheChartPoints(value, type: ValuePoint.self,
                               fundId: "coinbase-btc", entryCount: 7)
        // Reading as a different type returns nil, never a misinterpreted blob.
        let cross = cache.cachedChartPoints(type: PLPoint.self,
                                            fundId: "coinbase-btc", entryCount: 7)
        XCTAssertNil(cross)
    }

    // MARK: - Per-Fund Invalidation

    @MainActor
    func testInvalidateFundCacheClearsAllArtifactsForFund() {
        let cache = ChartCache.shared
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

    @MainActor
    func testClearNonEssentialCachesEmptiesEverything() {
        let cache = ChartCache.shared
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

    @MainActor
    func testDerivPointsNilStorageRemovesEntry() {
        let cache = ChartCache.shared
        // Caching `nil` should evict any existing entry — the production code uses
        // this to clear stale derivatives points when a fund is reclassified.
        cache.cacheDerivPoints([makeDerivPoint()], fundId: "fund-a", entryCount: 2)
        XCTAssertNotNil(cache.cachedDerivPoints(fundId: "fund-a", entryCount: 2))

        cache.cacheDerivPoints(nil, fundId: "fund-a", entryCount: 2)
        XCTAssertNil(cache.cachedDerivPoints(fundId: "fund-a", entryCount: 2))
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
