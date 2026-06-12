import XCTest
@testable import EscapeMint

/// Tests for `FundDataStore` stateful mutation paths and recompute behavior.
///
/// `FundDataStore.shared` is a `@MainActor` singleton whose mutations update the
/// in-memory `funds` array, recompute derived state (`portfolio`, `summaries`,
/// `summaryMap`, `actionableFunds`, `platforms`, `revision`), and persist to disk
/// via the shared `FundStore`. These tests exercise add / update / delete / rename /
/// append / replace / config-update against the live store, then assert on the
/// observable derived state.
///
/// Isolation strategy: the store is a singleton shared with other tests, so each
/// test uses a unique platform name and removes everything it creates in teardown.
/// Assertions are scoped to the funds a test created (by id) rather than absolute
/// counts of `store.funds`, so concurrent fixtures left by other suites can't make
/// these flaky. The recompute observers are NOT bootstrapped here (that only happens
/// inside `loadIfNeeded`), so no notification / Spotlight / widget side effects fire.
@MainActor
final class FundDataStoreTests: XCTestCase {

    private var store: FundDataStore { FundDataStore.shared }

    /// Unique per-test platform so created funds never collide across tests/suites.
    private var platform: String!
    /// Track every fund id created so teardown can purge memory + disk deterministically.
    private var createdIds: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        platform = "fdstest-\(UUID().uuidString.prefix(8).lowercased())"
        createdIds = []
    }

    override func tearDown() async throws {
        // Remove from disk and memory regardless of which mutation path created them.
        for id in createdIds {
            await store.deleteFund(id: id)
            try? await FundStore.shared.deleteFund(id: id)
        }
        createdIds = []
        try await super.tearDown()
    }

    // MARK: - Fund builders

    /// A trading fund with `manage_cash = true` so it carries its own cash and needs
    /// no sibling cash fund to compute a non-trivial summary.
    private func makeTradingFund(
        ticker: String,
        entries: [FundEntry]
    ) -> FundData {
        let config = FundConfig(
            fund_type: .stock,
            status: .active,
            target_apy: 0.12,
            interval_days: 7,
            input_min_usd: 100,
            input_mid_usd: 150,
            input_max_usd: 200,
            max_at_pct: -0.25,
            min_profit_usd: 50,
            cash_apy: 0.05,
            manage_cash: true,
            accumulate: true
        )
        return FundData(platform: platform, ticker: ticker, config: config, entries: entries)
    }

    private func makeCashFund(value: Double) -> FundData {
        let config = FundConfig(fund_type: .cash, status: .active, cash_apy: 0.05)
        return FundData(
            platform: platform,
            ticker: "cash",
            config: config,
            entries: [FundEntry(date: "2025-01-01", value: value, cash: value)]
        )
    }

    private func track(_ fund: FundData) {
        createdIds.append(fund.id)
    }

    private func sampleEntries() -> [FundEntry] {
        [
            FundEntry(date: "2025-01-01", value: 1000, cash: 1000, action: .BUY, amount: 1000, shares: 10, price: 100),
            FundEntry(date: "2025-01-08", value: 1100, cash: 0, action: .HOLD, shares: 10),
            FundEntry(date: "2025-01-15", value: 1200, cash: 0, action: .HOLD, shares: 10),
        ]
    }

    // MARK: - addFund / addFunds

    func testAddFundUpdatesMemoryAndDerivedState() async throws {
        let fund = makeTradingFund(ticker: "aaa", entries: sampleEntries())
        track(fund)

        let revisionBefore = store.revision
        await store.addFund(fund)

        // In-memory funds array
        XCTAssertNotNil(store.fund(byId: fund.id), "fund should be retrievable after addFund")
        // Derived summary recompute
        let summary = try XCTUnwrap(store.summary(byId: fund.id), "summary should be computed after addFund")
        XCTAssertEqual(summary.fund.id, fund.id)
        XCTAssertEqual(summary.currentValue, 1200, accuracy: 0.01, "summary reflects latest entry value")
        // Platforms derived set includes the new platform
        XCTAssertTrue(store.platforms.contains(platform), "platforms should include the new platform")
        // Revision bumped by the recompute
        XCTAssertGreaterThan(store.revision, revisionBefore, "revision should advance on recompute")
    }

    func testAddFundPersistsToDisk() async throws {
        let fund = makeTradingFund(ticker: "bbb", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        let onDisk = await FundStore.shared.readFundById(fund.id)
        let reloaded = try XCTUnwrap(onDisk, "addFund should persist the fund to disk")
        XCTAssertEqual(reloaded.entries.count, 3)
    }

    func testAddFundsBatchAddsAllWithSingleRecompute() async throws {
        let trading = makeTradingFund(ticker: "ccc", entries: sampleEntries())
        let cash = makeCashFund(value: 5000)
        track(trading)
        track(cash)

        let revisionBefore = store.revision
        await store.addFunds([trading, cash])

        XCTAssertNotNil(store.summary(byId: trading.id))
        XCTAssertNotNil(store.summary(byId: cash.id))
        // Both added in one in-memory update + one recompute → revision advances exactly once.
        XCTAssertEqual(store.revision, revisionBefore + 1, "addFunds should recompute exactly once for the batch")
    }

    func testAddFundsEmptyIsNoOp() async {
        let revisionBefore = store.revision
        await store.addFunds([])
        XCTAssertEqual(store.revision, revisionBefore, "empty addFunds should not recompute")
    }

    // MARK: - updateFund

    func testUpdateFundReplacesConfigAndRecomputes() async throws {
        let fund = makeTradingFund(ticker: "ddd", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        var updated = fund
        updated.config.target_apy = 0.42
        let revisionBefore = store.revision
        await store.updateFund(updated)

        let live = try XCTUnwrap(store.fund(byId: fund.id))
        XCTAssertEqual(live.config.target_apy, 0.42, "updateFund should replace the config in memory")
        XCTAssertGreaterThan(store.revision, revisionBefore, "updateFund should recompute")

        let onDiskRaw = await FundStore.shared.readFundById(fund.id)
        let onDisk = try XCTUnwrap(onDiskRaw)
        XCTAssertEqual(onDisk.config.target_apy, 0.42, "updateFund should persist the new config")
    }

    func testUpdateFundUnknownIdStillPersistsButDoesNotRecompute() async {
        // updateFund only mutates memory + recomputes when the id is known; the disk
        // write happens unconditionally (it will be a no-op create for a missing file).
        let revisionBefore = store.revision
        let ghost = makeTradingFund(ticker: "ghost", entries: sampleEntries())
        track(ghost) // ensure cleanup of any file the unconditional writeFund creates
        await store.updateFund(ghost)
        XCTAssertEqual(store.revision, revisionBefore, "unknown-id updateFund should not recompute in-memory state")
    }

    // MARK: - deleteFund

    func testDeleteFundRemovesFromMemoryAndDerivedState() async {
        let fund = makeTradingFund(ticker: "eee", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)
        XCTAssertNotNil(store.summary(byId: fund.id))

        let revisionBefore = store.revision
        await store.deleteFund(id: fund.id)

        XCTAssertNil(store.fund(byId: fund.id), "fund should be gone from memory")
        XCTAssertNil(store.summary(byId: fund.id), "summary should be dropped after delete")
        XCTAssertGreaterThan(store.revision, revisionBefore, "delete should recompute")

        let onDisk = await FundStore.shared.readFundById(fund.id)
        XCTAssertNil(onDisk, "deleteFund should remove the file from disk")
    }

    // MARK: - appendEntry / appendEntries

    func testAppendEntryUpdatesSummaryAndPersists() async throws {
        let fund = makeTradingFund(ticker: "fff", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)
        XCTAssertEqual(try XCTUnwrap(store.summary(byId: fund.id)).currentValue, 1200, accuracy: 0.01)

        let newEntry = FundEntry(date: "2025-01-22", value: 1500, cash: 0, action: .HOLD, shares: 10)
        await store.appendEntry(fundId: fund.id, entry: newEntry)

        // Optimistic inline summary update reflects the appended entry's value.
        let summary = try XCTUnwrap(store.summary(byId: fund.id))
        XCTAssertEqual(summary.currentValue, 1500, accuracy: 0.01, "appended entry should be reflected in the summary")
        XCTAssertEqual(try XCTUnwrap(store.fund(byId: fund.id)).entries.count, 4)

        let onDiskRaw = await FundStore.shared.readFundById(fund.id)
        let onDisk = try XCTUnwrap(onDiskRaw)
        XCTAssertEqual(onDisk.entries.count, 4, "appended entry should be persisted")
        XCTAssertEqual(onDisk.entries.last?.value ?? 0, 1500, accuracy: 0.01)
    }

    func testAppendEntryToUnknownFundIsNoOp() async {
        let revisionBefore = store.revision
        await store.appendEntries(writes: [(fundId: "\(platform!)-nonexistent", entry: FundEntry(date: "2025-01-01", value: 1))])
        // No fund matched → touched is empty, but recomputeWith still runs once on the
        // unchanged snapshot. Assert the unknown fund did not materialize a summary.
        XCTAssertNil(store.summary(byId: "\(platform!)-nonexistent"))
        XCTAssertGreaterThanOrEqual(store.revision, revisionBefore)
    }

    func testAppendEntriesEmptyIsNoOp() async {
        let revisionBefore = store.revision
        await store.appendEntries(writes: [])
        XCTAssertEqual(store.revision, revisionBefore, "empty appendEntries should not recompute")
    }

    // MARK: - replaceEntries

    func testReplaceEntriesSwapsHistoryAndRecomputes() async throws {
        let fund = makeTradingFund(ticker: "ggg", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        let replacement = [
            FundEntry(date: "2025-02-01", value: 2000, cash: 2000, action: .BUY, amount: 2000, shares: 20, price: 100),
            FundEntry(date: "2025-02-08", value: 2200, cash: 0, action: .HOLD, shares: 20),
        ]
        let revisionBefore = store.revision
        await store.replaceEntries(fundId: fund.id, entries: replacement)

        let live = try XCTUnwrap(store.fund(byId: fund.id))
        XCTAssertEqual(live.entries.count, 2, "replaceEntries should swap the whole history")
        XCTAssertEqual(try XCTUnwrap(store.summary(byId: fund.id)).currentValue, 2200, accuracy: 0.01)
        XCTAssertGreaterThan(store.revision, revisionBefore)

        let onDiskRaw = await FundStore.shared.readFundById(fund.id)
        let onDisk = try XCTUnwrap(onDiskRaw)
        XCTAssertEqual(onDisk.entries.count, 2, "replaceEntries should persist")
    }

    // MARK: - updateConfig

    func testUpdateConfigPersistsAndRecomputes() async throws {
        let fund = makeTradingFund(ticker: "hhh", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        var newConfig = fund.config
        newConfig.interval_days = 30
        let revisionBefore = store.revision
        await store.updateConfig(fundId: fund.id, config: newConfig)

        XCTAssertEqual(try XCTUnwrap(store.fund(byId: fund.id)).config.interval_days, 30)
        XCTAssertGreaterThan(store.revision, revisionBefore)

        let onDiskRaw = await FundStore.shared.readFundById(fund.id)
        let onDisk = try XCTUnwrap(onDiskRaw)
        XCTAssertEqual(onDisk.config.interval_days, 30, "updateConfig should persist")
    }

    // MARK: - renameFund

    func testRenamePreservingFundIdUpdatesMetadataKeepsIdAndFile() async throws {
        // Real UI rename path (EditFundView): the source fund's config already carries
        // `fund_id`, so `prepareRenameEdits` preserves identity — the id and on-disk file
        // stay stable, while the stored platform/ticker metadata changes. This keeps a
        // fund's history attached across a cosmetic platform/ticker rename.
        var startConfig = makeTradingFund(ticker: "iii", entries: sampleEntries()).config
        let originalId = "\(platform!)-iii"
        startConfig.fund_id = originalId
        let fund = FundData(platform: platform, ticker: "iii", config: startConfig, entries: sampleEntries())
        track(fund)
        await store.addFund(fund)
        XCTAssertEqual(fund.id, originalId)

        // Rename to a new ticker while preserving fund_id (matches EditFundView, which
        // mutates platform/ticker on the loaded fund whose config.fund_id is set).
        var renamed = fund
        renamed.ticker = "iii-renamed"
        let revisionBefore = store.revision
        await store.renameFund(from: originalId, to: renamed)

        // Identity is preserved (fund_id pinned), so the id does NOT change.
        XCTAssertEqual(renamed.id, originalId)
        let live = try XCTUnwrap(store.fund(byId: originalId), "renamed fund should still resolve under its preserved id")
        XCTAssertEqual(live.ticker, "iii-renamed", "ticker metadata should be updated")
        XCTAssertNotNil(store.summary(byId: originalId), "renamed fund should have a recomputed summary")
        XCTAssertGreaterThan(store.revision, revisionBefore, "rename should recompute")

        // Same on-disk file (keyed by the preserved id) reflects the new ticker.
        let onDiskRaw = await FundStore.shared.readFundById(originalId)
        let onDisk = try XCTUnwrap(onDiskRaw)
        XCTAssertEqual(onDisk.ticker, "iii-renamed", "renamed metadata should persist to the same file")
    }

    func testRenameToNewFundIdMovesDiskFiles() async throws {
        // When the rename target carries a *different* explicit fund_id, the store must
        // drop the old id and write the new one — deleting the stale file.
        var startConfig = makeTradingFund(ticker: "rrr", entries: sampleEntries()).config
        let oldId = "\(platform!)-rrr"
        startConfig.fund_id = oldId
        let fund = FundData(platform: platform, ticker: "rrr", config: startConfig, entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        var renamedConfig = startConfig
        let newId = "\(platform!)-rrr-new"
        renamedConfig.fund_id = newId
        let renamed = FundData(platform: platform, ticker: "rrr", config: renamedConfig, entries: fund.entries)
        track(renamed)
        await store.renameFund(from: oldId, to: renamed)

        XCTAssertEqual(renamed.id, newId)
        XCTAssertNil(store.fund(byId: oldId), "old id should be gone after id-changing rename")
        XCTAssertNotNil(store.fund(byId: newId), "new id should be present after rename")
        XCTAssertNotNil(store.summary(byId: newId), "renamed fund should have a fresh summary")

        let oldOnDisk = await FundStore.shared.readFundById(oldId)
        let newOnDisk = await FundStore.shared.readFundById(newId)
        XCTAssertNil(oldOnDisk, "old file should be deleted when fund_id changes")
        XCTAssertNotNil(newOnDisk, "new file should exist after rename")
    }

    // MARK: - filteredPortfolio

    func testFilteredPortfolioNilReturnsWholePortfolio() async {
        let fund = makeTradingFund(ticker: "jjj", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        let whole = store.filteredPortfolio(platform: nil)
        XCTAssertEqual(whole.totalValue, store.portfolio.totalValue, accuracy: 0.01,
                       "filteredPortfolio(nil) should equal the precomputed portfolio")
    }

    func testFilteredPortfolioByPlatformAggregatesOnlyMatchingFunds() async {
        // Two funds on this test's unique platform; filtering by it should aggregate
        // exactly their value, independent of whatever else lives in the store.
        let a = makeTradingFund(ticker: "kkk", entries: sampleEntries())   // current value 1200
        let b = makeTradingFund(ticker: "lll", entries: [
            FundEntry(date: "2025-01-01", value: 500, cash: 500, action: .BUY, amount: 500, shares: 5, price: 100),
            FundEntry(date: "2025-01-08", value: 700, cash: 0, action: .HOLD, shares: 5),
        ])
        track(a)
        track(b)
        await store.addFunds([a, b])

        let filtered = store.filteredPortfolio(platform: platform)
        // 1200 + 700 = 1900 across the two funds on this platform.
        XCTAssertEqual(filtered.totalValue, 1900, accuracy: 0.01,
                       "platform filter should aggregate only this platform's funds")
    }

    func testFilteredPortfolioUnknownPlatformIsEmpty() async {
        let fund = makeTradingFund(ticker: "mmm", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        let filtered = store.filteredPortfolio(platform: "platform-that-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(filtered.totalValue, 0, accuracy: 0.01, "unknown platform should aggregate to empty")
    }

    // MARK: - Per-fund metrics cache / recompute

    func testRecomputeReusesCacheForUntouchedFundButRefreshesTouched() async throws {
        let touched = makeTradingFund(ticker: "nnn", entries: sampleEntries())
        let untouched = makeTradingFund(ticker: "ooo", entries: sampleEntries())
        track(touched)
        track(untouched)
        await store.addFunds([touched, untouched])

        let untouchedBefore = try XCTUnwrap(store.summary(byId: untouched.id)).currentValue

        // Append to only the touched fund. The untouched fund's cached metrics should be
        // reused (its summary value is unchanged), while the touched fund's summary updates.
        await store.appendEntry(fundId: touched.id, entry: FundEntry(date: "2025-01-22", value: 1700, cash: 0, action: .HOLD, shares: 10))

        XCTAssertEqual(try XCTUnwrap(store.summary(byId: touched.id)).currentValue, 1700, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(store.summary(byId: untouched.id)).currentValue, untouchedBefore, accuracy: 0.01,
                       "untouched fund's summary should be unchanged across the recompute")
    }

    // MARK: - auditEntries lazy cache invalidation

    func testAuditEntriesInvalidatedAfterMutation() async {
        let fund = makeTradingFund(ticker: "ppp", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)

        let countBefore = store.auditEntries.filter { $0.fundId == fund.id }.count
        XCTAssertEqual(countBefore, 3)

        await store.appendEntry(fundId: fund.id, entry: FundEntry(date: "2025-01-22", value: 1500, action: .HOLD))

        let countAfter = store.auditEntries.filter { $0.fundId == fund.id }.count
        XCTAssertEqual(countAfter, 4, "audit cache should be rebuilt after a mutation adds an entry")
    }

    // MARK: - Error-toast surfacing (lastDiskWriteError)

    func testLastDiskWriteErrorIsObservableMutableState() {
        // The root view observes `lastDiskWriteError` and shows a toast when a disk
        // write fails; the store sets it via `recordDiskError`. It starts nil on a
        // clean mutation, and can be cleared by the view after presenting the toast.
        store.lastDiskWriteError = "Couldn't save changes (test). Changes may be lost on next launch."
        XCTAssertNotNil(store.lastDiskWriteError)
        store.lastDiskWriteError = nil
        XCTAssertNil(store.lastDiskWriteError, "view should be able to clear the error after surfacing it")
    }

    func testSuccessfulMutationLeavesNoDiskWriteError() async {
        store.lastDiskWriteError = nil
        let fund = makeTradingFund(ticker: "qqq", entries: sampleEntries())
        track(fund)
        await store.addFund(fund)
        XCTAssertNil(store.lastDiskWriteError, "a successful add should not surface a disk-write error")
    }
}
