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

    /// Minimal `FundStoreProtocol` fake backed by an in-memory `[id: FundData]` map.
    private final class FakeFundStore: FundStoreProtocol, @unchecked Sendable {
        private struct State {
            var funds: [String: FundData] = [:]
            var writeCount = 0
            var appendCount = 0
            var deleteCount = 0
            var backupCount = 0
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())

        init(seed: [FundData] = []) {
            lock.withLock { state in
                for fund in seed { state.funds[fund.id] = fund }
            }
        }

        // Inspection helpers for assertions.
        var writeCount: Int { lock.withLock { $0.writeCount } }
        var appendCount: Int { lock.withLock { $0.appendCount } }
        var deleteCount: Int { lock.withLock { $0.deleteCount } }
        var backupCount: Int { lock.withLock { $0.backupCount } }
        func storedFund(_ id: String) -> FundData? { lock.withLock { $0.funds[id] } }

        // iCloud lifecycle: this fake is purely local, so it always reports "no iCloud".
        nonisolated var isICloud: Bool { false }
        func hasICloudAccount() -> Bool { false }
        func retryICloudIfNeeded(maxAttempts: Int, delay: Duration) async -> Bool { false }
        func migrateToICloudIfNeeded() async {}

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
            lock.withLock { state in
                guard state.funds[fundId] != nil else { return }
                state.funds[fundId]?.entries.append(entry)
                state.appendCount += 1
            }
        }
        func replaceEntries(fundId: String, entries: [FundEntry]) async throws {
            lock.withLock { state in
                state.funds[fundId]?.entries = entries
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
}
