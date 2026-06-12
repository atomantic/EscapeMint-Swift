import XCTest
@testable import EscapeMint

/// Tests for FundDetailViewModel — verifies the orchestration extracted from
/// FundDetailView.task: it computes entry rows (and derivatives points for
/// derivatives funds) off the main thread and caches them in ChartCache, and is
/// a no-op when the cache is already warm. ChartCache is a `@MainActor` singleton,
/// so caches are cleared between tests.
@MainActor
final class FundDetailViewModelTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        ChartCache.shared.clearNonEssentialCaches()
    }

    override func tearDown() async throws {
        ChartCache.shared.clearNonEssentialCaches()
        try await super.tearDown()
    }

    func testLoadComputedDataCachesEntryRows() async {
        let cache = ChartCache.shared
        let vm = FundDetailViewModel(cache: cache)
        var config = FundConfig()
        config.fund_type = .stock
        let entries = stockEntries()

        XCTAssertNil(cache.cachedRows(fundId: "coinbase-btc", entryCount: entries.count))

        await vm.loadComputedData(fundId: "coinbase-btc", entries: entries, config: config)

        let rows = cache.cachedRows(fundId: "coinbase-btc", entryCount: entries.count)
        XCTAssertNotNil(rows, "Entry rows must be cached after load")
        XCTAssertEqual(rows?.count, entries.count)
    }

    func testNonDerivativesFundDoesNotCacheDerivPoints() async {
        let cache = ChartCache.shared
        let vm = FundDetailViewModel(cache: cache)
        var config = FundConfig()
        config.fund_type = .stock
        let entries = stockEntries()

        await vm.loadComputedData(fundId: "coinbase-btc", entries: entries, config: config)

        XCTAssertNil(cache.cachedDerivPoints(fundId: "coinbase-btc", entryCount: entries.count),
                     "Non-derivatives funds must not produce cached derivatives points")
    }

    func testNonDerivativesLoadClearsStaleDerivPoints() async {
        let cache = ChartCache.shared
        let vm = FundDetailViewModel(cache: cache)
        var config = FundConfig()
        config.fund_type = .stock
        let entries = stockEntries()

        // Simulate stale derivatives points left over from a prior classification.
        cache.cacheDerivPoints([], fundId: "coinbase-btc", entryCount: entries.count)
        XCTAssertNotNil(cache.cachedDerivPoints(fundId: "coinbase-btc", entryCount: entries.count))

        await vm.loadComputedData(fundId: "coinbase-btc", entries: entries, config: config)

        XCTAssertNil(cache.cachedDerivPoints(fundId: "coinbase-btc", entryCount: entries.count),
                     "Loading a non-derivatives fund must evict stale derivatives points")
    }

    func testDerivativesFundCachesDerivPoints() async {
        let cache = ChartCache.shared
        let vm = FundDetailViewModel(cache: cache)
        var config = FundConfig()
        config.fund_type = .derivatives
        let entries = [
            FundEntry(date: "2025-01-01", value: 0, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2025-01-02", value: 0, action: .BUY, amount: 1000, price: 1000, contracts: 1, fee: 0),
            FundEntry(date: "2025-01-10", value: 0, action: .SELL, amount: 1100, price: 1100, contracts: 1, fee: 0)
        ]

        await vm.loadComputedData(fundId: "deriv-fund", entries: entries, config: config)

        XCTAssertNotNil(cache.cachedRows(fundId: "deriv-fund", entryCount: entries.count))
        XCTAssertNotNil(cache.cachedDerivPoints(fundId: "deriv-fund", entryCount: entries.count),
                        "Derivatives funds must cache derivatives chart points")
    }

    func testLoadIsNoOpWhenRowsAlreadyCached() async {
        let cache = ChartCache.shared
        let vm = FundDetailViewModel(cache: cache)
        var config = FundConfig()
        config.fund_type = .stock
        let entries = stockEntries()

        // Pre-seed a sentinel row set; load must not overwrite it.
        let sentinel = [makeRow(extracted: 999)]
        cache.cacheRows(sentinel, fundId: "coinbase-btc", entryCount: entries.count)

        await vm.loadComputedData(fundId: "coinbase-btc", entries: entries, config: config)

        let rows = cache.cachedRows(fundId: "coinbase-btc", entryCount: entries.count)
        XCTAssertEqual(rows?.count, 1, "Cached rows must be left untouched")
        XCTAssertEqual(rows?.first?.extracted, 999)
    }

    // MARK: - Helpers

    private func stockEntries() -> [FundEntry] {
        [
            FundEntry(date: "2025-01-01", value: 0, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2025-01-02", value: 1000, cash: 9000, action: .BUY, amount: 1000, shares: 10, price: 100),
            FundEntry(date: "2025-01-10", value: 1200, cash: 9000, action: .HOLD)
        ]
    }

    private func makeRow(extracted: Double) -> ComputedEntryRow {
        ComputedEntryRow(
            extracted: extracted,
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
}
