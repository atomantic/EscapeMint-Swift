import Foundation
import os
import SwiftUI

/// Shared in-memory cache for all fund data. Progressive loading: configs first (instant nav),
/// then entries streamed in parallel. Mutations update memory + disk together.
@MainActor @Observable
final class FundDataStore {
    static let shared = FundDataStore()

    /// Disk-I/O backend. Defaults to the `FundStore.shared` singleton in production;
    /// tests inject a fake conforming to `FundStoreProtocol` to drive the load /
    /// mutation paths without touching the real filesystem (issue #72).
    private let store: FundStoreProtocol
    /// Test seam used to force the suspension window between detached computation
    /// and main-actor application. Production passes `nil`.
    private let beforeApplyingRecompute: (@MainActor () async -> Void)?

    enum LoadingPhase: Equatable {
        case idle
        case checkingICloud
        case loadingConfigs
        case loadingEntries
        case computingPortfolio
        case ready

        var message: String {
            switch self {
            case .idle:
                "Preparing portfolio"
            case .checkingICloud:
                "Checking iCloud portfolio files"
            case .loadingConfigs:
                "Loading fund definitions"
            case .loadingEntries:
                "Streaming transaction history"
            case .computingPortfolio:
                "Computing portfolio signals"
            case .ready:
                "Portfolio ready"
            }
        }
    }

    private(set) var funds: [FundData] = []
    private(set) var isLoaded = false
    private(set) var loadingPhase: LoadingPhase = .idle

    /// True once configs are loaded (fund names/platforms visible). Entries may still be streaming.
    private(set) var isConfigLoaded = false

    /// How many funds have their entries loaded (0 until streaming begins)
    private(set) var loadedFundCount: Int = 0

    /// 0.0 to 1.0 — derived from loadedFundCount / funds.count
    var loadProgress: Double {
        funds.isEmpty ? 1.0 : Double(loadedFundCount) / Double(funds.count)
    }

    /// Incremented on every recompute — views can observe this to invalidate caches
    private(set) var revision: Int = 0

    /// Every in-memory mutation receives a generation before it starts detached
    /// derived-state work. A later mutation wins; an older detached recompute is
    /// never allowed to install its captured snapshot over that newer committed state.
    private var mutationGeneration = 0
    private var activeReloadGeneration: Int?

    private func beginMutation() -> Int {
        mutationGeneration += 1
        return mutationGeneration
    }

    private func isCurrentMutation(_ generation: Int) -> Bool {
        mutationGeneration == generation
    }

    /// Derived work is allowed to observe only the aggregate already committed
    /// to `funds`. A later mutation simply owns the next recompute.
    private func recomputeCommittedState(generation: Int) async {
        guard isCurrentMutation(generation) else { return }
        await recomputeWith(funds, generation: generation)
    }

    /// Set whenever a mutation's disk write fails. The root view observes this
    /// and shows a toast so the user knows their change didn't persist, instead
    /// of discovering it silently on next relaunch / iCloud reload.
    var lastDiskWriteError: String?

    private func recordDiskError(_ context: String, _ error: Error) {
        Self.logger.error("\(context, privacy: .public) disk op failed: \(error)")
        lastDiskWriteError = "Couldn't save changes (\(context)). Changes may be lost on next launch."
    }

    // Pre-computed derived state (updated on every refresh)
    private(set) var portfolio = PortfolioMetrics()
    private(set) var summaries: [FundSummary] = []
    private(set) var summaryMap: [String: FundSummary] = [:]
    private(set) var actionableFunds: [ActionableFund] = []
    private(set) var platforms: [String] = []

    /// Per-fund metrics cache. Keyed by fundId → (version, metrics, state).
    /// `fundVersions[fundId]` is bumped on any mutation to that fund's entries or
    /// config. On recompute, funds whose cached version matches the current
    /// version skip `computeFundMetricsForFund` entirely — so adding one entry
    /// to one fund no longer walks every other fund's full history.
    private var fundVersions: [String: Int] = [:]
    private struct CachedFundMetrics {
        let version: Int
        let metrics: FundMetrics
        let state: FundState
    }
    private var fundMetricsCache: [String: CachedFundMetrics] = [:]

    private func bumpFundVersion(_ fundId: String) {
        fundVersions[fundId, default: 0] += 1
    }

    /// Audit entries are computed lazily — only when first accessed after a recompute
    private var _auditEntries: [AuditEntry]?
    var auditEntries: [AuditEntry] {
        if let cached = _auditEntries { return cached }
        let entries = Self.buildAuditEntries(from: funds)
        _auditEntries = entries
        return entries
    }

    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "FundDataStore")

    init(
        store: FundStoreProtocol = FundStore.shared,
        beforeApplyingRecompute: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.beforeApplyingRecompute = beforeApplyingRecompute
    }

    // MARK: - Recompute Observers

    /// Snapshot handed to recompute observers so they react to the latest derived
    /// state without the store reaching into Services / ChartCache / AppKit itself.
    struct RecomputeContext: Sendable {
        let funds: [FundData]
        let actionableCount: Int
    }

    private var recomputeObservers: [@MainActor (RecomputeContext) -> Void] = []
    private var fundInvalidationObservers: [@MainActor (String) -> Void] = []
    private var didBootstrapObservers = false

    /// Register a side-effect that should run after every recompute. Observers own any
    /// debounce / task cancellation they need; the store just hands them the context.
    func addRecomputeObserver(_ observer: @escaping @MainActor (RecomputeContext) -> Void) {
        recomputeObservers.append(observer)
    }

    /// Register a callback invoked with a fundId whenever that fund's entries change,
    /// so presentation caches can drop their per-fund data without the store importing
    /// the cache type.
    func addFundInvalidationObserver(_ observer: @escaping @MainActor (String) -> Void) {
        fundInvalidationObservers.append(observer)
    }

    private func notifyFundInvalidated(_ fundId: String) {
        for observer in fundInvalidationObservers { observer(fundId) }
    }

    /// Register the app's standard post-recompute side effects (services rescheduling,
    /// chart precompute, macOS dock badge) exactly once. Called from `loadIfNeeded` so
    /// tests that exercise recompute directly never wire up notification/Spotlight/widget
    /// side effects. No-op if observers are already registered (e.g. set up by a test).
    private func bootstrapRecomputeObserversIfNeeded() {
        guard !didBootstrapObservers else { return }
        didBootstrapObservers = true
        if recomputeObservers.isEmpty {
            registerDefaultRecomputeObservers()
        }
    }

    // MARK: - Initial Load (Progressive)

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        bootstrapRecomputeObserversIfNeeded()

        // Yield immediately so the UI (intro guide sheet) can finish rendering
        await Task.yield()

        loadingPhase = .checkingICloud

        // Initialize FundStore on a background thread — url(forUbiquityContainerIdentifier:)
        // can block 10+ seconds on first launch with a new Apple ID and MUST NOT run on main thread
        let store = store
        let isICloud = await Task.detached(priority: .userInitiated) { store.isICloud }.value

        // If iCloud wasn't available at init (e.g. after reboot), retry before loading
        if !isICloud {
            // Keep launch responsive when iCloud is slow to hand back the ubiquity
            // container. Do a short foreground retry, then keep trying after the UI
            // is usable via `scheduleDeferredICloudRecoveryIfNeeded()`.
            let recovered = await store.retryICloudIfNeeded(maxAttempts: 2, delay: .milliseconds(300))
            if recovered {
                Self.logger.info("☁️ iCloud recovered after retry, loading from iCloud")
            }
        }

        do {
            try await store.migrateToICloudIfNeeded()
        } catch {
            recordDiskError("migrating local funds to iCloud", error)
        }

        // Phase 1: Load configs off the main thread (nonisolated does synchronous file I/O)
        loadingPhase = .loadingConfigs
        let configs = await Task.detached(priority: .userInitiated) {
            store.readAllFundConfigs()
        }.value
        funds = configs
        loadedFundCount = 0
        platforms = Array(Set(configs.map(\.platform))).sorted()
        isConfigLoaded = true

        if configs.isEmpty {
            isLoaded = true
            loadingPhase = .ready
            scheduleDeferredICloudRecoveryIfNeeded()
            return
        }

        // Yield so SwiftUI can render the initial layout before we start heavy work
        await Task.yield()

        // Phase 2: Load all entries off the main thread, then apply in one shot
        loadingPhase = .loadingEntries
        await loadEntriesProgressively()
        isLoaded = true
        loadingPhase = .ready
        scheduleDeferredICloudRecoveryIfNeeded()
    }

    /// Load TSV entries concurrently off the main thread, apply in batches with yields.
    /// Streaming results keeps the progress indicator moving even when one large
    /// TSV file takes longer than the rest.
    private func loadEntriesProgressively() async {
        let fundIds = funds.map(\.id)
        let batchSize = max(1, min(12, max(1, fundIds.count / 4)))
        var pending: [(String, [FundEntry])] = []
        pending.reserveCapacity(batchSize)
        var completedCount = 0
        let store = store

        await withTaskGroup(of: (String, [FundEntry]).self) { group in
            for id in fundIds {
                group.addTask(priority: .userInitiated) {
                    let entries = store.readFundEntries(id: id)
                    return (id, entries)
                }
            }

            for await result in group {
                pending.append(result)
                completedCount += 1
                guard pending.count >= batchSize else {
                    loadedFundCount = completedCount
                    continue
                }
                applyLoadedEntries(pending)
                pending.removeAll(keepingCapacity: true)
                loadedFundCount = completedCount
                await Task.yield()
            }
        }

        if !pending.isEmpty {
            applyLoadedEntries(pending)
            loadedFundCount = completedCount
            await Task.yield()
        }
        loadingPhase = .computingPortfolio
        await recompute()
    }

    private func applyLoadedEntries(_ loaded: [(String, [FundEntry])]) {
        for (id, entries) in loaded {
            if let idx = funds.firstIndex(where: { $0.id == id }) {
                funds[idx].entries = entries
            }
        }
    }

    private func scheduleDeferredICloudRecoveryIfNeeded() {
        guard !store.isICloud else { return }
        guard deferredICloudRecoveryTask == nil else { return }
        deferredICloudRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { deferredICloudRecoveryTask = nil }
            guard await store.hasICloudAccount() else { return }
            let recovered = await store.retryICloudIfNeeded(maxAttempts: 4, delay: .seconds(1))
            guard recovered else { return }
            do {
                try await store.migrateToICloudIfNeeded()
            } catch {
                recordDiskError("migrating local funds to iCloud", error)
            }
            await self.reload()
            ICloudSyncMonitor.shared.startMonitoring()
        }
    }

    // MARK: - Reload from Disk

    func reload() async {
        let generation = beginMutation()
        activeReloadGeneration = generation
        loadingPhase = .loadingEntries
        let loaded = await store.readAllFunds()

        // A user mutation or newer reload committed while the actor read was in
        // flight. Never replace that newer authoritative aggregate with this disk
        // snapshot. Only this reload may clear its own loading indicator.
        guard isCurrentMutation(generation) else {
            if activeReloadGeneration == generation {
                activeReloadGeneration = nil
                loadingPhase = .ready
            }
            return
        }
        funds = loaded
        loadedFundCount = loaded.count
        // Entries re-read from disk may differ — drop cached per-fund metrics.
        fundMetricsCache.removeAll()
        for fund in loaded { bumpFundVersion(fund.id) }
        isConfigLoaded = true
        isLoaded = true
        await recomputeWith(loaded, generation: generation)
        if activeReloadGeneration == generation {
            activeReloadGeneration = nil
            loadingPhase = .ready
        }
    }

    // MARK: - Accessors

    func fund(byId id: String) -> FundData? {
        funds.first { $0.id == id }
    }

    func summary(byId id: String) -> FundSummary? {
        summaryMap[id]
    }

    /// Aggregate portfolio metrics for the summaries on a single platform, or the
    /// whole portfolio when `platform` is nil.
    ///
    /// Lives here (not in the dashboard view) so the filter-then-aggregate path is
    /// observable from `@Observable` state and unit-testable without a view. When
    /// `platform` is nil the result equals the precomputed `portfolio`, so callers
    /// can pass their current filter directly.
    func filteredPortfolio(platform: String?) -> PortfolioMetrics {
        guard let platform else { return portfolio }
        let matching = summaries.filter { $0.fund.platform == platform }
        return computePortfolioAggregate(
            matching.map { $0.fund },
            perFundMetrics: matching.map { ($0.metrics, $0.state) }
        )
    }

    // MARK: - Storage Facade (views route disk ops through here, not FundStore.shared)

    /// True when funds are stored in the iCloud ubiquity container rather than local Documents.
    /// Exposed so Settings can render iCloud-specific controls without touching the file-I/O actor.
    var isICloud: Bool {
        store.isICloud
    }

    /// On-disk fund count + total byte size, for the Settings storage summary.
    func dataStats() async -> FundStore.DataStats {
        await store.dataStats()
    }

    /// Number of test/demo funds currently on disk (platforms prefixed with "test").
    func testFundCount() async -> Int {
        await store.testFundCount()
    }

    /// Import funds from a TSV+JSON directory, reloading in-memory state when anything was imported.
    /// Returns the imported fund count.
    func importFromDirectory(_ url: URL) async throws -> Int {
        let count = try await store.importFromDirectory(url)
        if count > 0 { await reload() }
        return count
    }

    /// Inspect a backup JSON without importing — used to validate the file before a replace/merge.
    func backupJSONFundCount(_ url: URL) async throws -> Int {
        try await store.backupJSONFundCount(url)
    }

    /// Import funds from a backup JSON. Replacement is performed inside the storage
    /// actor as one staged transaction, so a malformed/empty backup cannot erase the
    /// current portfolio before its usable records are known.
    /// Returns the imported fund count.
    func importFromBackupJSON(_ url: URL, replacingExisting: Bool) async throws -> Int {
        let count: Int
        if replacingExisting {
            count = try await store.replaceAllFundsFromBackupJSON(url)
        } else {
            count = try await store.importFromBackupJSON(url)
        }
        ICloudSyncMonitor.shared.markLocalWrite()
        await reload()
        return count
    }

    /// Export all funds to a single backup JSON file, returning its URL.
    func exportToBackupJSON() async throws -> URL {
        try await store.exportToBackupJSON()
    }

    /// Generate simulated test funds with DCA history, then reload in-memory state.
    /// Returns the number of test funds created.
    func loadTestData() async throws -> Int {
        let count = try await store.loadTestData()
        await reload()
        return count
    }

    /// Delete all test/demo funds, then reload in-memory state. Returns the deleted count.
    func deleteTestFunds() async throws -> Int {
        let count = try await store.deleteTestFunds()
        await reload()
        return count
    }

    /// Back up all funds to Documents (when any exist), delete everything, then reload in-memory
    /// state. Returns the fund count that was backed up before clearing.
    func clearAllDataWithBackup() async throws -> Int {
        let stats = await store.dataStats()
        if stats.fundCount > 0 {
            _ = try await store.exportToDocuments()
        }
        try await store.deleteAllFunds()
        await reload()
        return stats.fundCount
    }

    // MARK: - Mutations (memory first for instant UI, then persist to disk)

    func addFund(_ fund: FundData) async {
        await addFunds([fund])
    }

    /// Add multiple funds with one in-memory update and one recompute. Creating a
    /// trading fund plus its platform cash fund used to run the full portfolio
    /// recompute twice from one button tap.
    func addFunds(_ newFunds: [FundData]) async {
        guard !newFunds.isEmpty else { return }
        let generation = beginMutation()
        funds.append(contentsOf: newFunds)
        loadedFundCount = funds.count
        for fund in newFunds {
            bumpFundVersion(fund.id)
        }
        var didWrite = false
        for fund in newFunds {
            do {
                // Write the latest in-memory state, NOT the captured `fund` parameter — a
                // concurrent updateConfig that landed during `await recompute()` would have
                // mutated funds[idx], and writing the old captured snapshot would clobber it.
                guard let toWrite = funds.first(where: { $0.id == fund.id }) else { continue }
                try await store.writeFund(toWrite)
                didWrite = true
            } catch {
                recordDiskError("adding fund", error)
            }
        }
        if didWrite {
            ICloudSyncMonitor.shared.markLocalWrite()
        }
        await recomputeCommittedState(generation: generation)
    }

    func updateFund(_ fund: FundData) async {
        guard let idx = funds.firstIndex(where: { $0.id == fund.id }) else { return }
        let generation = beginMutation()
        funds[idx] = fund
        bumpFundVersion(fund.id)
        do {
            try await store.writeFund(fund)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            recordDiskError("updating fund", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    /// Atomic fund rename: single recompute + disk swap. Convenience wrapper
    /// around `renameFunds` for a single-fund rename.
    func renameFund(from oldId: String, to newFund: FundData) async {
        await renameFunds([(oldId, newFund)])
    }

    /// Batch rename: apply N platform/ticker changes with a SINGLE recompute +
    /// side-effect pass. Renaming a platform with 20 funds was previously
    /// triggering 20 recomputes, notification reschedules, widget refreshes.
    func renameFunds(_ edits: [(oldId: String, newFund: FundData)]) async {
        guard !edits.isEmpty else { return }
        let generation = beginMutation()
        let preparedEdits = Self.prepareRenameEdits(edits)
        let snapshot = Self.applyRenames(to: funds, edits: preparedEdits)
        for (oldId, newFund) in preparedEdits {
            forgetFund(id: oldId)
            bumpFundVersion(newFund.id)
        }
        funds = snapshot
        loadedFundCount = funds.count
        do {
            try await store.renameFunds(preparedEdits)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            recordDiskError("renaming funds", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    private func forgetFund(id: String) {
        fundMetricsCache.removeValue(forKey: id)
        fundVersions.removeValue(forKey: id)
    }

    /// Pure helper for rename-snapshot computation. Exposed for tests so the
    /// rename semantics can be verified without exercising disk I/O.
    nonisolated static func applyRenames(to funds: [FundData], edits: [(oldId: String, newFund: FundData)]) -> [FundData] {
        var snapshot = funds
        for (oldId, newFund) in edits {
            if let idx = snapshot.firstIndex(where: { $0.id == oldId }) {
                snapshot[idx] = newFund
            }
        }
        return snapshot
    }

    /// Preserve fund identity across platform/ticker renames. Legacy funds may
    /// not have `__fund_id` yet, so the current file-backed ID is stamped into
    /// the renamed config before the snapshot is recomputed or written.
    nonisolated static func prepareRenameEdits(_ edits: [(oldId: String, newFund: FundData)]) -> [(oldId: String, newFund: FundData)] {
        var preparedEdits = edits.map { edit in
            var prepared = edit.newFund
            if prepared.config.fund_id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                prepared.config.fund_id = edit.oldId
            }
            return (oldId: edit.oldId, newFund: prepared)
        }

        let renamedIds = Dictionary(uniqueKeysWithValues: preparedEdits.map { ($0.oldId, $0.newFund.id) })
        let defaultCashByOldPlatform = Dictionary(uniqueKeysWithValues: preparedEdits.compactMap { edit -> (String, String)? in
            guard edit.newFund.ticker == "cash",
                  let oldPlatform = oldPlatformName(from: edit.oldId, ticker: edit.newFund.ticker) else {
                return nil
            }
            return (oldPlatform, edit.newFund.id)
        })

        for index in preparedEdits.indices {
            var fund = preparedEdits[index].newFund
            if let cashFundId = fund.config.cash_fund,
               let renamedCashFundId = renamedIds[cashFundId] {
                fund.config.cash_fund = renamedCashFundId
            } else if fund.config.manage_cash == false,
                      fund.config.cash_fund == nil,
                      let oldPlatform = oldPlatformName(from: preparedEdits[index].oldId, ticker: fund.ticker),
                      let renamedCashFundId = defaultCashByOldPlatform[oldPlatform] {
                fund.config.cash_fund = renamedCashFundId
            }
            preparedEdits[index].newFund = fund
        }

        return preparedEdits
    }

    private nonisolated static func oldPlatformName(from oldId: String, ticker: String) -> String? {
        let suffix = "-\(ticker)"
        guard oldId.hasSuffix(suffix), oldId.count > suffix.count else { return nil }
        return String(oldId.dropLast(suffix.count))
    }

    func deleteFund(id: String) async {
        let generation = beginMutation()
        funds.removeAll { $0.id == id }
        loadedFundCount = funds.count
        forgetFund(id: id)
        do {
            try await store.deleteFund(id: id)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            recordDiskError("deleting fund", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    func deletePlatform(named platform: String) async {
        let cleanPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanPlatform.isEmpty else { return }
        let generation = beginMutation()

        let removedIds = funds
            .filter { $0.platform == cleanPlatform }
            .map(\.id)
        let snapshot = Self.applyPlatformDeletion(to: funds, platform: cleanPlatform)

        for id in removedIds {
            forgetFund(id: id)
        }
        funds = snapshot
        loadedFundCount = min(loadedFundCount, snapshot.count)

        do {
            let deletedCount = try await store.deletePlatform(named: cleanPlatform)
            if deletedCount > 0 || !removedIds.isEmpty {
                ICloudSyncMonitor.shared.markLocalWrite()
            }
        } catch {
            recordDiskError("deleting platform \(cleanPlatform)", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    nonisolated static func applyPlatformDeletion(to funds: [FundData], platform: String) -> [FundData] {
        let cleanPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return funds.filter { $0.platform != cleanPlatform }
    }

    func appendEntry(fundId: String, entry: FundEntry) async {
        await appendEntries(writes: [(fundId, entry)])
    }

    /// Append multiple entries in one atomic recompute + one iCloud sync marker.
    /// The snapshot pattern keeps `funds` and derived state in sync within the
    /// same frame (no intermediate stale-summary render).
    func appendEntries(writes: [(fundId: String, entry: FundEntry)]) async {
        guard !writes.isEmpty else { return }
        let generation = beginMutation()
        var snapshot = funds
        var touched: [String] = []
        for (fundId, entry) in writes {
            if let idx = snapshot.firstIndex(where: { $0.id == fundId }) {
                snapshot[idx].entries.append(entry)
                touched.append(fundId)
            }
        }
        for fundId in touched {
            bumpFundVersion(fundId)
            notifyFundInvalidated(fundId)
        }

        // Optimistic fast-path: apply updated funds + freshly-computed summaries
        // for the touched funds inline on MainActor so UI (recommendation card,
        // Equity, etc.) reflects the new entry this frame, without waiting for
        // the full-portfolio recompute's detached hop to complete. Portfolio
        // aggregates lag by one write until `recomputeWith` finishes below.
        funds = snapshot
        for fundId in touched {
            if let fund = snapshot.first(where: { $0.id == fundId }) {
                summaryMap[fundId] = FundSummary(fund, allFunds: snapshot)
            }
        }
        revision += 1

        do {
            // One store call is the ordering boundary for the complete logical
            // transaction. A primary+cash pair must not admit a replacement or
            // deletion between its two disk appends.
            try await store.appendEntries(writes)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            recordDiskError("saving entries", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) async {
        guard let idx = funds.firstIndex(where: { $0.id == fundId }) else { return }
        let generation = beginMutation()
        funds[idx].entries = entries
        bumpFundVersion(fundId)
        notifyFundInvalidated(fundId)
        do {
            try await store.replaceEntries(fundId: fundId, entries: entries)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            recordDiskError("saving entries", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    func updateConfig(fundId: String, config: FundConfig) async {
        guard let idx = funds.firstIndex(where: { $0.id == fundId }) else { return }
        let generation = beginMutation()
        funds[idx].config = config
        bumpFundVersion(fundId)
        do {
            // updateConfig returns false when the fund file doesn't exist yet — this happens
            // when an updateConfig races ahead of addFund's initial writeFund. Without a
            // fallback the user's edit would be silently lost. Materialize the latest
            // in-memory state directly via writeFund so the edit becomes durable.
            let wrote = try await store.updateConfig(fundId: fundId, config: config)
            if wrote {
                ICloudSyncMonitor.shared.markLocalWrite()
                notifyFundInvalidated(fundId)
            } else {
                // Re-read after the suspension: a concurrent delete must not be
                // recreated, while a concurrent edit should be materialized whole.
                if let committedFund = funds.first(where: { $0.id == fundId }) {
                    try await store.writeFund(committedFund)
                    ICloudSyncMonitor.shared.markLocalWrite()
                    notifyFundInvalidated(fundId)
                }
            }
        } catch {
            recordDiskError("updating config", error)
        }
        await recomputeCommittedState(generation: generation)
    }

    // MARK: - Advanced Tools (Recalculate / Interpolate)

    /// Shared preamble for the destructive advanced-tools operations: resolve the fund,
    /// back it up to disk, then run `operation` with the fund. Returns the operation's
    /// result, or a failure tuple if the fund is missing or the backup fails (so the
    /// caller never mutates data it couldn't back up first).
    private func withBackup(
        fundId: String,
        operation: (FundData) async -> (success: Bool, message: String)
    ) async -> (success: Bool, message: String) {
        guard let fund = fund(byId: fundId) else {
            return (false, "Fund not found")
        }
        do {
            _ = try await store.backupFund(id: fundId)
        } catch {
            return (false, "Backup failed: \(error.localizedDescription)")
        }
        return await operation(fund)
    }

    /// Backup fund, recalculate fund_size for all entries, save to disk.
    func recalculateFund(fundId: String) async -> (success: Bool, message: String) {
        await withBackup(fundId: fundId) { fund in
            let config = fund.config
            let entries = fund.entries
            let recalculated = await Task.detached(priority: .userInitiated) {
                recalculateFundSize(entries: entries, config: config)
            }.value

            await replaceEntries(fundId: fundId, entries: recalculated)
            return (true, "Recalculated fund_size for \(recalculated.count) entries")
        }
    }

    /// Backup fund, recalculate prices from amount/shares, save to disk.
    func recalculatePrices(fundId: String) async -> (success: Bool, message: String) {
        await withBackup(fundId: fundId) { fund in
            let entries = fund.entries
            let dd = fund.config.dollarDec
            let (updatedEntries, updated) = await Task.detached(priority: .userInitiated) {
                recalculateEntryPrices(entries: entries, dollarDecimals: dd)
            }.value

            if updated > 0 {
                await replaceEntries(fundId: fundId, entries: updatedEntries)
            }
            return (true, "Recalculated \(updated) prices (\(entries.count) entries)")
        }
    }

    /// Backup fund, interpolate missing values for a column, save to disk.
    func interpolateFundColumn(fundId: String, column: InterpolatableColumn) async -> (success: Bool, message: String) {
        await withBackup(fundId: fundId) { fund in
            let entries = fund.entries
            let (updatedEntries, result) = await Task.detached(priority: .userInitiated) {
                interpolateColumn(column, entries: entries)
            }.value

            if result.interpolated > 0 {
                await replaceEntries(fundId: fundId, entries: updatedEntries)
            }
            return (true, "Interpolated \(result.interpolated) \(column.label) values (\(result.knownValues) known of \(result.totalEntries))")
        }
    }

    // MARK: - Recompute Derived State

    /// Holds the result of expensive background computation
    private struct ComputeResult: Sendable {
        let portfolio: PortfolioMetrics
        let summaries: [FundSummary]
        let summaryMap: [String: FundSummary]
        let actionableFunds: [ActionableFund]
        let platforms: [String]
        let freshMetrics: [(FundMetrics, FundState)]
    }

    private func recompute() async {
        await recomputeWith(funds, generation: mutationGeneration)
    }

#if DEBUG
    /// Synchronously populate the store with sample funds and derived state for
    /// SwiftUI `#Preview` rendering. DEBUG-only — never compiled into Release and
    /// never used at runtime. Mirrors the derived-state assignment in `recomputeWith`
    /// but runs inline (no background task) so previews render immediately.
    func seedForPreview(_ sampleFunds: [FundData], asOfDate: String) {
        let perFund = sampleFunds.map { computeFundMetricsForFund($0, asOfDate: asOfDate) }
        let portfolioMetrics = computePortfolioAggregate(sampleFunds, perFundMetrics: perFund)
        let computedSummaries = computeSummariesFromPortfolio(funds: sampleFunds, portfolio: portfolioMetrics)
            .sorted { $0.currentValue > $1.currentValue }
        var map: [String: FundSummary] = [:]
        for s in computedSummaries { map[s.fund.id] = s }

        funds = sampleFunds
        portfolio = portfolioMetrics
        summaries = computedSummaries
        summaryMap = map
        actionableFunds = computeActionableFunds(sampleFunds, asOfDate: asOfDate)
        platforms = Array(Set(sampleFunds.map(\.platform))).sorted()
        _auditEntries = nil
        isLoaded = true
        isConfigLoaded = true
        loadingPhase = .ready
        revision += 1
    }
#endif

    /// Per-fund metrics are cached by `(fundId, version)`. Funds whose version
    /// is unchanged since the last recompute reuse their cached metrics — so
    /// appending one entry to one fund only walks that fund's entries, not the
    /// entire portfolio's.
    private func recomputeWith(_ snapshot: [FundData], generation: Int? = nil) async {
        let expectedGeneration = generation ?? mutationGeneration
        let today = todayString()
        var cachedPerFund: [(FundMetrics, FundState)?] = Array(repeating: nil, count: snapshot.count)
        var stale: [(index: Int, fundId: String, version: Int)] = []
        stale.reserveCapacity(snapshot.count)
        for (i, fund) in snapshot.enumerated() {
            let version = fundVersions[fund.id, default: 0]
            if let cached = fundMetricsCache[fund.id], cached.version == version {
                cachedPerFund[i] = (cached.metrics, cached.state)
            } else {
                stale.append((i, fund.id, version))
            }
        }

        let staleIndices = stale.map(\.index)
        let staleFunds = staleIndices.map { snapshot[$0] }
        let result: ComputeResult = await Task.detached(priority: .userInitiated) {
            let fresh = staleFunds.map { computeFundMetricsForFund($0, asOfDate: today) }
            var perFund: [(FundMetrics, FundState)] = []
            perFund.reserveCapacity(snapshot.count)
            var freshIter = fresh.makeIterator()
            for slot in cachedPerFund {
                if let slot { perFund.append(slot) }
                else if let next = freshIter.next() { perFund.append(next) }
            }
            let portfolio = computePortfolioAggregate(snapshot, perFundMetrics: perFund)
            let summaries = computeSummariesFromPortfolio(funds: snapshot, portfolio: portfolio)
                .sorted { $0.currentValue > $1.currentValue }
            var map: [String: FundSummary] = [:]
            for s in summaries { map[s.fund.id] = s }
            let actionable = computeActionableFunds(snapshot)
            let platforms = Array(Set(snapshot.map(\.platform))).sorted()
            return ComputeResult(
                portfolio: portfolio,
                summaries: summaries,
                summaryMap: map,
                actionableFunds: actionable,
                platforms: platforms,
                freshMetrics: fresh
            )
        }.value

        if let beforeApplyingRecompute {
            await beforeApplyingRecompute()
        }

        // A later mutation committed while detached work was running. Its recompute
        // owns the live state, so discard this stale result rather than restoring the
        // older snapshot (and never schedule persistence from it).
        guard isCurrentMutation(expectedGeneration) else { return }

        // Update per-fund cache with fresh metrics, drop entries for vanished funds.
        for (j, entry) in stale.enumerated() {
            let (m, s) = result.freshMetrics[j]
            fundMetricsCache[entry.fundId] = CachedFundMetrics(version: entry.version, metrics: m, state: s)
        }
        let liveIds = Set(snapshot.map(\.id))
        fundMetricsCache = fundMetricsCache.filter { liveIds.contains($0.key) }

        // `funds` was committed synchronously before detached work began. Only
        // install derived state here; assigning the captured snapshot would make
        // recompute another authoritative mutation path.
        portfolio = result.portfolio
        summaries = result.summaries
        summaryMap = result.summaryMap
        actionableFunds = result.actionableFunds
        platforms = result.platforms

        // Invalidate lazy audit cache
        _auditEntries = nil

        revision += 1

        historyCacheTask?.cancel()
        historyCacheTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistHistoryCachesIfNeeded(from: result.summaries)
        }

        // Hand the new derived state to registered observers (chart precompute, the
        // debounced services side effects, the macOS dock badge). The store no longer
        // references ChartCache / Services / AppKit directly. Observers own their own
        // debounce + cancellation.
        let context = RecomputeContext(funds: funds, actionableCount: actionableFunds.count)
        for observer in recomputeObservers { observer(context) }
    }

    private var deferredICloudRecoveryTask: Task<Void, Never>?
    private var historyCacheTask: Task<Void, Never>?

    private func persistHistoryCachesIfNeeded(from summaries: [FundSummary]) async {
        var updates: [(id: String, cache: FundHistoryCache)] = []
        for summary in summaries where summary.fund.config.status == .closed {
            // Reuse the fingerprint computed during FundSummary.buildClosedMetrics — recomputing
            // it here would double the O(n) hashing per recompute and partially offset the cache.
            guard let fingerprint = summary.closedHistoryFingerprint else { continue }
            let current = summary.fund.config.history_cache
            if current?.entryFingerprint == fingerprint, current?.closedMetrics != nil { continue }
            updates.append((summary.fund.id, FundHistoryCache(entryFingerprint: fingerprint, closedMetrics: summary.closedMetrics)))
        }
        guard !updates.isEmpty else { return }

        var anyWritten = false
        for item in updates {
            // Re-entrancy: this is @MainActor but each `await` is a suspension point. Use
            // `updateHistoryCache` which does a read-modify-write of just the `history_cache`
            // slot on disk — that way a concurrent edit to *other* config fields (chart_bounds,
            // dollar_decimals, etc.) made between recompute and this write isn't clobbered by
            // a stale in-memory snapshot. Likewise we patch only `history_cache` on the live
            // `funds` array. Only mutate in-memory state when the write actually hit disk —
            // `updateHistoryCache` returns false (no throw) if the fund file doesn't exist yet
            // (addFund/recompute can race ahead of the initial writeFund).
            do {
                let wrote = try await store.updateHistoryCache(fundId: item.id, cache: item.cache)
                if wrote {
                    // Track disk writes independently of the in-memory patch: if the fund was
                    // concurrently removed/renamed between awaits, the bytes still hit disk and
                    // we must call markLocalWrite() so iCloud doesn't bounce our own write back
                    // as a reload.
                    anyWritten = true
                    if let idx = funds.firstIndex(where: { $0.id == item.id }) {
                        funds[idx].config.history_cache = item.cache
                    }
                }
            } catch {
                recordDiskError("persisting history cache", error)
            }
        }
        // Suppress the iCloud reload-loop our own writes would otherwise trigger.
        if anyWritten { ICloudSyncMonitor.shared.markLocalWrite() }
    }

    static func buildAuditEntries(from funds: [FundData]) -> [AuditEntry] {
        var entries: [AuditEntry] = []
        entries.reserveCapacity(funds.reduce(0) { $0 + $1.entries.count })
        for fund in funds {
            for entry in fund.entries {
                entries.append(AuditEntry(
                    id: "\(fund.id)-\(entry.id)",
                    date: entry.date,
                    ticker: fund.ticker,
                    platform: fund.platform,
                    fundId: fund.id,
                    value: entry.value,
                    action: entry.action,
                    amount: entry.amount,
                    dividend: entry.dividend,
                    expense: entry.expense,
                    notes: entry.notes
                ))
            }
        }
        return entries.sorted { $0.date > $1.date }
    }
}
