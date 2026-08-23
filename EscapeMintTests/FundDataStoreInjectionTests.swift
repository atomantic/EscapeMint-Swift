import XCTest
import os
@testable import EscapeMint

/// Proves the `FundStoreProtocol` seam added in issue #72: `FundDataStore` can be
/// driven against an in-memory fake instead of the real `FundStore.shared`
/// singleton, so its load / mutation / persist orchestration is unit-testable
/// without touching the filesystem or iCloud.
///
/// `FakeFundStore` keeps funds in a lock-guarded dictionary (it must be `Sendable`
/// because `FundDataStore` is `@MainActor` and captures the store in the detached
/// load tasks). It records each persistence call so the tests can assert the store
/// actually delegated the write, not just that in-memory state changed.
@MainActor
final class FundDataStoreInjectionTests: XCTestCase {

    /// Coordinates a single forced suspension after detached recompute work has
    /// completed but before its snapshot may be applied on the main actor.
    private actor RecomputeGate {
        private var hasPaused = false
        private var released = false
        private var callCount = 0
        private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pauseOnce() async {
            callCount += 1
            let ready = callWaiters.filter { callCount >= $0.count }
            callWaiters.removeAll { callCount >= $0.count }
            for waiter in ready { waiter.continuation.resume() }
            guard !hasPaused else { return }
            hasPaused = true
            guard !released else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitForCalls(_ expectedCount: Int) async {
            if callCount >= expectedCount { return }
            await withCheckedContinuation { callWaiters.append((expectedCount, $0)) }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// Holds a persistence operation while a later replacement attempts to
    /// enter the same serialized storage boundary.
    private actor BatchPersistenceGate {
        private var isHeld = false
        private var isReleased = false
        private var replacementAttempted = false
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private var replacementWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func hold() async {
            isHeld = true
            let waiters = heldWaiters
            heldWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            guard !isReleased else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilHeld() async {
            if isHeld { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func noteReplacementAttempted() {
            replacementAttempted = true
            let waiters = replacementWaiters
            replacementWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func waitForReplacementAttempt() async {
            if replacementAttempted { return }
            await withCheckedContinuation { replacementWaiters.append($0) }
        }

        func release() {
            isReleased = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// Minimal `FundStoreProtocol` fake backed by an in-memory `[id: FundData]` map.
    private final class FakeFundStore: FundStoreProtocol, @unchecked Sendable {
        private struct State {
            var funds: [String: FundData] = [:]
            var writeCount = 0
            var appendCount = 0
            var singleAppendCallCount = 0
            var batchAppendCallCount = 0
            var deleteCount = 0
            var backupCount = 0
            var batchInFlight = false
            var batchWaiters: [CheckedContinuation<Void, Never>] = []
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        private let batchPersistenceGate: BatchPersistenceGate?

        init(seed: [FundData] = [], batchPersistenceGate: BatchPersistenceGate? = nil) {
            self.batchPersistenceGate = batchPersistenceGate
            lock.withLock { state in
                for fund in seed { state.funds[fund.id] = fund }
            }
        }

        // Inspection helpers for assertions.
        var writeCount: Int { lock.withLock { $0.writeCount } }
        var appendCount: Int { lock.withLock { $0.appendCount } }
        var singleAppendCallCount: Int { lock.withLock { $0.singleAppendCallCount } }
        var batchAppendCallCount: Int { lock.withLock { $0.batchAppendCallCount } }
        var deleteCount: Int { lock.withLock { $0.deleteCount } }
        var backupCount: Int { lock.withLock { $0.backupCount } }
        func storedFund(_ id: String) -> FundData? { lock.withLock { $0.funds[id] } }

        // iCloud lifecycle: this fake is purely local, so it always reports "no iCloud".
        nonisolated var isICloud: Bool { false }
        func hasICloudAccount() -> Bool { false }
        func retryICloudIfNeeded(maxAttempts: Int, delay: Duration) async -> Bool { false }
        func migrateToICloudIfNeeded() async throws {}

        // Reads
        nonisolated func readAllFundConfigs() -> [FundData] {
            lock.withLock { Array($0.funds.values) }.map {
                FundData(platform: $0.platform, ticker: $0.ticker, config: $0.config, entries: [])
            }
        }
        nonisolated func readFundEntries(id: String) -> [FundEntry] {
            lock.withLock { $0.funds[id]?.entries ?? [] }
        }
        func readAllFunds() async -> [FundData] {
            lock.withLock { Array($0.funds.values) }
        }

        // Mutations
        func writeFund(_ fund: FundData) async throws {
            lock.withLock { state in
                state.funds[fund.id] = fund
                state.writeCount += 1
            }
        }
        func appendEntry(fundId: String, entry: FundEntry) async throws {
            let shouldHold = lock.withLock { state in
                guard state.funds[fundId] != nil else { return false }
                state.funds[fundId]?.entries.append(entry)
                state.appendCount += 1
                state.singleAppendCallCount += 1
                return state.singleAppendCallCount == 1 && batchPersistenceGate != nil
            }
            if shouldHold { await batchPersistenceGate?.hold() }
        }
        func appendEntries(_ writes: [(fundId: String, entry: FundEntry)]) async throws {
            guard let batchPersistenceGate else {
                lock.withLock { state in
                    state.batchAppendCallCount += 1
                    for write in writes where state.funds[write.fundId] != nil {
                        state.funds[write.fundId]?.entries.append(write.entry)
                        state.appendCount += 1
                    }
                }
                return
            }

            lock.withLock { state in
                state.batchAppendCallCount += 1
                state.batchInFlight = true
            }
            await batchPersistenceGate.hold()
            let waiters = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
                for write in writes where state.funds[write.fundId] != nil {
                    state.funds[write.fundId]?.entries.append(write.entry)
                    state.appendCount += 1
                }
                state.batchInFlight = false
                let waiters = state.batchWaiters
                state.batchWaiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
        func replaceEntries(fundId: String, entries: [FundEntry]) async throws {
            var waitedForBatch = false
            if let batchPersistenceGate {
                let mustWait = lock.withLock { $0.batchInFlight }
                if mustWait {
                    waitedForBatch = true
                    await batchPersistenceGate.noteReplacementAttempted()
                    await withCheckedContinuation { continuation in
                        lock.withLock { state in
                            if state.batchInFlight {
                                state.batchWaiters.append(continuation)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
            lock.withLock { state in
                state.funds[fundId]?.entries = entries
            }
            if let batchPersistenceGate, !waitedForBatch {
                await batchPersistenceGate.noteReplacementAttempted()
            }
        }
        @discardableResult
        func updateConfig(fundId: String, config: FundConfig) async throws -> Bool {
            lock.withLock { state in
                guard state.funds[fundId] != nil else { return false }
                state.funds[fundId]?.config = config
                return true
            }
        }
        @discardableResult
        func updateHistoryCache(fundId: String, cache: FundHistoryCache?) async throws -> Bool {
            lock.withLock { state in
                guard state.funds[fundId] != nil else { return false }
                state.funds[fundId]?.config.history_cache = cache
                return true
            }
        }
        func deleteFund(id: String) async throws {
            lock.withLock { state in
                if state.funds.removeValue(forKey: id) != nil { state.deleteCount += 1 }
            }
        }
        func deletePlatform(named platform: String) async throws -> Int {
            lock.withLock { state in
                let ids = state.funds.values.filter { $0.platform == platform }.map(\.id)
                for id in ids { state.funds.removeValue(forKey: id) }
                return ids.count
            }
        }
        func backupFund(id: String) async throws -> URL {
            lock.withLock { $0.backupCount += 1 }
            return URL(fileURLWithPath: "/dev/null/\(id)")
        }

        // Bulk import/export + test-data facade operations. The injection tests don't
        // exercise these paths, so they return inert in-memory results derived from the
        // seeded map — enough to satisfy the protocol without touching the filesystem.
        func dataStats() async -> FundStore.DataStats {
            lock.withLock { FundStore.DataStats(fundCount: $0.funds.count, totalBytes: 0) }
        }
        func testFundCount() async -> Int {
            lock.withLock { state in state.funds.values.filter { $0.platform.hasPrefix("test") }.count }
        }
        func importFromDirectory(_ sourceDir: URL) async throws -> Int { 0 }
        func backupJSONFundCount(_ jsonURL: URL) async throws -> Int { 0 }
        func importFromBackupJSON(_ jsonURL: URL) async throws -> Int { 0 }
        func replaceAllFundsFromBackupJSON(_ jsonURL: URL) async throws -> Int { 0 }
        func exportToBackupJSON() async throws -> URL { URL(fileURLWithPath: "/dev/null/backup.json") }
        func exportToDocuments() async throws -> URL { URL(fileURLWithPath: "/dev/null/export") }
        func loadTestData() async throws -> Int { 0 }
        func deleteTestFunds() async throws -> Int {
            lock.withLock { state in
                let ids = state.funds.values.filter { $0.platform.hasPrefix("test") }.map(\.id)
                for id in ids { state.funds.removeValue(forKey: id) }
                return ids.count
            }
        }
        func deleteAllFunds() async throws {
            lock.withLock { $0.funds.removeAll() }
        }
    }

    private func makeFund(platform: String, ticker: String, entries: [FundEntry]) -> FundData {
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

    private func sampleEntries() -> [FundEntry] {
        [
            FundEntry(date: "2025-01-01", value: 1000, cash: 1000, action: .BUY, amount: 1000, shares: 10, price: 100),
            FundEntry(date: "2025-01-08", value: 1100, cash: 0, action: .HOLD, shares: 10),
            FundEntry(date: "2025-01-15", value: 1200, cash: 0, action: .HOLD, shares: 10),
        ]
    }

    /// loadIfNeeded streams configs + entries from the injected fake and recomputes
    /// derived state — no real filesystem touched.
    func testLoadIfNeededReadsFromInjectedFake() async throws {
        let seeded = makeFund(platform: "fakestore", ticker: "btc", entries: sampleEntries())
        let fake = FakeFundStore(seed: [seeded])
        let store = FundDataStore(store: fake)

        await store.loadIfNeeded()

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.loadingPhase, .ready)
        let summary = try XCTUnwrap(store.summary(byId: seeded.id),
                                    "summary should be computed from the fake's seeded fund")
        XCTAssertEqual(summary.currentValue, 1200, accuracy: 0.01,
                       "derived state should reflect the fake's streamed entries")
    }

    /// addFund persists through the protocol seam (write delegated to the fake) and
    /// updates in-memory derived state.
    func testAddFundPersistsThroughInjectedFake() async throws {
        let fake = FakeFundStore()
        let store = FundDataStore(store: fake)

        let fund = makeFund(platform: "fakestore", ticker: "eth", entries: sampleEntries())
        await store.addFund(fund)

        XCTAssertNotNil(store.summary(byId: fund.id), "addFund should recompute a summary")
        XCTAssertEqual(fake.writeCount, 1, "addFund should delegate exactly one write to the injected store")
        let persisted = try XCTUnwrap(fake.storedFund(fund.id), "fund should have been written to the fake")
        XCTAssertEqual(persisted.entries.count, 3)
    }

    /// appendEntry + deleteFund both route through the fake, proving the mutation
    /// paths are exercised against the seam (not FundStore.shared).
    func testAppendThenDeleteRouteThroughInjectedFake() async throws {
        let seeded = makeFund(platform: "fakestore", ticker: "sol", entries: sampleEntries())
        let fake = FakeFundStore(seed: [seeded])
        let store = FundDataStore(store: fake)
        await store.loadIfNeeded()

        let newEntry = FundEntry(date: "2025-01-22", value: 1500, cash: 0, action: .HOLD, shares: 10)
        await store.appendEntry(fundId: seeded.id, entry: newEntry)
        XCTAssertEqual(fake.appendCount, 1, "appendEntry should delegate to the fake")
        XCTAssertEqual(fake.storedFund(seeded.id)?.entries.count, 4)
        XCTAssertEqual(try XCTUnwrap(store.summary(byId: seeded.id)).currentValue, 1500, accuracy: 0.01)

        await store.deleteFund(id: seeded.id)
        XCTAssertEqual(fake.deleteCount, 1, "deleteFund should delegate to the fake")
        XCTAssertNil(fake.storedFund(seeded.id), "fund should be gone from the fake after delete")
        XCTAssertNil(store.summary(byId: seeded.id), "summary should be dropped after delete")
    }

    /// A primary entry and its cash counterpart are one logical disk mutation.
    /// The replacement attempts to enter while that batch is held; it must run
    /// after the whole batch, so the replaced cash history cannot retain a ghost row.
    func testLogicalAppendBatchCannotInterleaveWithCashReplacement() async throws {
        let primary = makeFund(platform: "batch", ticker: "asset", entries: sampleEntries())
        let cash = makeFund(platform: "batch", ticker: "cash", entries: sampleEntries())
        let gate = BatchPersistenceGate()
        let fake = FakeFundStore(seed: [primary, cash], batchPersistenceGate: gate)
        let store = FundDataStore(store: fake)
        await store.loadIfNeeded()

        let primaryEntry = FundEntry(date: "2025-02-01", value: 1300, action: .BUY, amount: 100)
        let cashEntry = FundEntry(date: "2025-02-01", value: 900, action: .WITHDRAW, amount: 100)
        let replacement = [FundEntry(date: "2025-03-01", value: 750, action: .HOLD)]

        async let appending: Void = store.appendEntries(writes: [
            (primary.id, primaryEntry),
            (cash.id, cashEntry),
        ])
        await gate.waitUntilHeld()

        async let replacing: Void = store.replaceEntries(fundId: cash.id, entries: replacement)
        await gate.waitForReplacementAttempt()
        await gate.release()
        await appending
        await replacing

        XCTAssertEqual(fake.batchAppendCallCount, 1)
        XCTAssertEqual(fake.singleAppendCallCount, 0,
                       "facade must not split a logical batch into per-entry calls")
        XCTAssertEqual(fake.storedFund(primary.id)?.entries.last?.date, primaryEntry.date)
        XCTAssertEqual(fake.storedFund(cash.id)?.entries.map(\.date), replacement.map(\.date),
                       "replacement ordered after the batch must remove the cash counterpart")
        XCTAssertEqual(store.fund(byId: cash.id)?.entries.map(\.date), replacement.map(\.date))
    }

    /// A config-only edit must publish fresh derived state after consumers have primed
    /// their view of the fund. It advances the revision/recompute contract and sends
    /// the per-fund invalidation used by caches that retain config-derived display data.
    func testConfigOnlyUpdatePublishesRecomputeAndRevisionAfterStateIsPrimed() async throws {
        let seeded = makeFund(platform: "fakestore", ticker: "config", entries: sampleEntries())
        let fake = FakeFundStore(seed: [seeded])
        let store = FundDataStore(store: fake)
        await store.loadIfNeeded()

        // Prime the observable state a view/cache would already be using.
        XCTAssertNotNil(store.summary(byId: seeded.id))
        _ = store.auditEntries
        let revisionBefore = store.revision
        var recomputeContexts: [FundDataStore.RecomputeContext] = []
        var entryInvalidations: [String] = []
        store.addRecomputeObserver { recomputeContexts.append($0) }
        store.addFundInvalidationObserver { entryInvalidations.append($0) }

        var edited = seeded.config
        edited.target_apy = 0.77
        await store.updateConfig(fundId: seeded.id, config: edited)

        XCTAssertEqual(store.revision, revisionBefore + 1,
                       "config-only changes must invalidate revision-based consumers")
        XCTAssertEqual(recomputeContexts.count, 1,
                       "recompute observers must receive the new config-only state")
        XCTAssertEqual(recomputeContexts[0].funds.first?.config.target_apy, 0.77)
        XCTAssertEqual(store.summary(byId: seeded.id)?.fund.config.target_apy, 0.77)
        XCTAssertEqual(entryInvalidations, [seeded.id],
                       "config-only edits must invalidate cached presentation for this fund")
        XCTAssertEqual(fake.storedFund(seeded.id)?.config.target_apy, 0.77)
    }

    /// The first mutation's detached recompute is deliberately stopped immediately
    /// before it can install its captured snapshot. A newer config edit must remain
    /// both in memory and in the injected persistence backend after the old task is
    /// released; this is the stale-snapshot/data-loss interleaving from #1.
    func testNewerMutationWinsWhenOlderDetachedRecomputeResumes() async throws {
        let fake = FakeFundStore()
        let gate = RecomputeGate()
        let store = FundDataStore(store: fake) {
            await gate.pauseOnce()
        }
        let fund = makeFund(platform: "race", ticker: "btc", entries: sampleEntries())

        async let adding: Void = store.addFund(fund)
        await gate.waitForCalls(1)

        var newerConfig = fund.config
        newerConfig.target_apy = 0.77
        async let updating: Void = store.updateConfig(fundId: fund.id, config: newerConfig)
        // The second call has committed its generation and passed the same
        // pre-apply seam; only then release the older result.
        await gate.waitForCalls(2)
        await gate.release()
        await adding
        await updating

        let live = try XCTUnwrap(store.fund(byId: fund.id))
        XCTAssertEqual(live.config.target_apy, 0.77)
        let persisted = try XCTUnwrap(fake.storedFund(fund.id))
        XCTAssertEqual(persisted.config.target_apy, 0.77)
    }
}
