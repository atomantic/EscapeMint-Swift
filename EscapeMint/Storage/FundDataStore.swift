import Foundation
import os
import SwiftUI

/// Shared in-memory cache for all fund data. Progressive loading: configs first (instant nav),
/// then entries streamed in parallel. Mutations update memory + disk together.
@MainActor @Observable
final class FundDataStore {
    static let shared = FundDataStore()

    private(set) var funds: [FundData] = []
    private(set) var isLoaded = false

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

    private init() {}

    // MARK: - Initial Load (Progressive)

    func loadIfNeeded() async {
        guard !isLoaded else { return }

        // Yield immediately so the UI (intro guide sheet) can finish rendering
        await Task.yield()

        // Initialize FundStore on a background thread — url(forUbiquityContainerIdentifier:)
        // can block 10+ seconds on first launch with a new Apple ID and MUST NOT run on main thread
        let isICloud = await Task.detached(priority: .userInitiated) { FundStore.shared.isICloud }.value

        // If iCloud wasn't available at init (e.g. after reboot), retry before loading
        if !isICloud {
            let recovered = await FundStore.shared.retryICloudIfNeeded()
            if recovered {
                Self.logger.info("☁️ iCloud recovered after retry, loading from iCloud")
            }
        }

        await FundStore.shared.migrateToICloudIfNeeded()

        // Phase 1: Load configs off the main thread (nonisolated does synchronous file I/O)
        let configs = await Task.detached(priority: .userInitiated) {
            FundStore.shared.readAllFundConfigs()
        }.value
        funds = configs
        loadedFundCount = 0
        platforms = Array(Set(configs.map(\.platform))).sorted()
        isConfigLoaded = true

        if configs.isEmpty {
            isLoaded = true
            return
        }

        // Yield so SwiftUI can render the initial layout before we start heavy work
        await Task.yield()

        // Phase 2: Load all entries off the main thread, then apply in one shot
        await loadEntriesProgressively()
        isLoaded = true
    }

    /// Load TSV entries concurrently off the main thread, apply in batches with yields
    private func loadEntriesProgressively() async {
        let fundIds = funds.map(\.id)

        // Do ALL file I/O in a single detached task — nothing touches the main thread
        let allEntries: [(String, [FundEntry])] = await Task.detached(priority: .userInitiated) {
            // Use a task group for parallel reads, collect all results
            await withTaskGroup(of: (String, [FundEntry]).self, returning: [(String, [FundEntry])].self) { group in
                for id in fundIds {
                    group.addTask {
                        let entries = FundStore.shared.readFundEntries(id: id)
                        return (id, entries)
                    }
                }
                var results: [(String, [FundEntry])] = []
                results.reserveCapacity(fundIds.count)
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }.value

        // Apply entry data in batches (yielding between) for UI fairness,
        // but defer the engine recompute until all entries are in place.
        let batchSize = max(1, allEntries.count / 3) // ~3 batches
        for batchStart in stride(from: 0, to: allEntries.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allEntries.count)
            for i in batchStart..<batchEnd {
                let (id, entries) = allEntries[i]
                if let idx = funds.firstIndex(where: { $0.id == id }) {
                    funds[idx].entries = entries
                }
            }
            loadedFundCount = batchEnd
            await Task.yield()
        }
        await recompute()
    }

    // MARK: - Reload from Disk

    func reload() async {
        let loaded = await FundStore.shared.readAllFunds()
        funds = loaded
        loadedFundCount = loaded.count
        // Entries re-read from disk may differ — drop cached per-fund metrics.
        fundMetricsCache.removeAll()
        for fund in loaded { bumpFundVersion(fund.id) }
        isConfigLoaded = true
        isLoaded = true
        await recompute()
    }

    // MARK: - Accessors

    func fund(byId id: String) -> FundData? {
        funds.first { $0.id == id }
    }

    func summary(byId id: String) -> FundSummary? {
        summaryMap[id]
    }

    // MARK: - Mutations (memory first for instant UI, then persist to disk)

    func addFund(_ fund: FundData) async {
        funds.append(fund)
        loadedFundCount = funds.count
        bumpFundVersion(fund.id)
        await recompute()
        do {
            try await FundStore.shared.writeFund(fund)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("addFund disk write failed: \(error)")
        }
    }

    func updateFund(_ fund: FundData) async {
        if let idx = funds.firstIndex(where: { $0.id == fund.id }) {
            funds[idx] = fund
            bumpFundVersion(fund.id)
            await recompute()
        }
        do {
            try await FundStore.shared.writeFund(fund)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("updateFund disk write failed: \(error)")
        }
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
        var snapshot = funds
        for (oldId, newFund) in edits {
            if let idx = snapshot.firstIndex(where: { $0.id == oldId }) {
                snapshot[idx] = newFund
            }
            forgetFund(id: oldId)
            bumpFundVersion(newFund.id)
        }
        await recomputeWith(snapshot)
        var anyWriteSucceeded = false
        for (oldId, newFund) in edits {
            do {
                try await FundStore.shared.writeFund(newFund)
                if oldId != newFund.id {
                    try await FundStore.shared.deleteFund(id: oldId)
                }
                anyWriteSucceeded = true
            } catch {
                Self.logger.error("renameFunds disk op failed for \(oldId): \(error)")
            }
        }
        if anyWriteSucceeded {
            ICloudSyncMonitor.shared.markLocalWrite()
        }
    }

    private func forgetFund(id: String) {
        fundMetricsCache.removeValue(forKey: id)
        fundVersions.removeValue(forKey: id)
    }

    func deleteFund(id: String) async {
        funds.removeAll { $0.id == id }
        loadedFundCount = funds.count
        forgetFund(id: id)
        await recompute()
        do {
            try await FundStore.shared.deleteFund(id: id)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("deleteFund disk delete failed: \(error)")
        }
    }

    func appendEntry(fundId: String, entry: FundEntry) async {
        await appendEntries(writes: [(fundId, entry)])
    }

    /// Append multiple entries in one atomic recompute + one iCloud sync marker.
    /// The snapshot pattern keeps `funds` and derived state in sync within the
    /// same frame (no intermediate stale-summary render).
    func appendEntries(writes: [(fundId: String, entry: FundEntry)]) async {
        guard !writes.isEmpty else { return }
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
            ViewCache.shared.invalidateFundCache(fundId: fundId)
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

        await recomputeWith(snapshot)

        var didWrite = false
        for (fundId, entry) in writes {
            do {
                try await FundStore.shared.appendEntry(fundId: fundId, entry: entry)
                didWrite = true
            } catch {
                Self.logger.error("appendEntries disk write failed for \(fundId): \(error)")
            }
        }
        if didWrite {
            ICloudSyncMonitor.shared.markLocalWrite()
        }
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) async {
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            // Compute with updated entries BEFORE mutating funds,
            // so the view never sees new entries with stale summaries
            var snapshot = funds
            snapshot[idx].entries = entries
            bumpFundVersion(fundId)
            ViewCache.shared.invalidateFundCache(fundId: fundId)
            await recomputeWith(snapshot)
        }
        do {
            try await FundStore.shared.replaceEntries(fundId: fundId, entries: entries)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("replaceEntries disk write failed: \(error)")
        }
    }

    func updateConfig(fundId: String, config: FundConfig) async {
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            var snapshot = funds
            snapshot[idx].config = config
            bumpFundVersion(fundId)
            await recomputeWith(snapshot)
        }
        do {
            try await FundStore.shared.updateConfig(fundId: fundId, config: config)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("updateConfig disk write failed: \(error)")
        }
    }

    // MARK: - Advanced Tools (Recalculate / Interpolate)

    /// Backup fund, recalculate fund_size for all entries, save to disk.
    func recalculateFund(fundId: String) async -> (success: Bool, message: String) {
        guard let fund = fund(byId: fundId) else {
            return (false, "Fund not found")
        }
        // Backup first
        do {
            _ = try await FundStore.shared.backupFund(id: fundId)
        } catch {
            return (false, "Backup failed: \(error.localizedDescription)")
        }

        let config = fund.config
        let entries = fund.entries
        let recalculated = await Task.detached(priority: .userInitiated) {
            recalculateFundSize(entries: entries, config: config)
        }.value

        await replaceEntries(fundId: fundId, entries: recalculated)
        return (true, "Recalculated fund_size for \(recalculated.count) entries")
    }

    /// Backup fund, recalculate prices from amount/shares, save to disk.
    func recalculatePrices(fundId: String) async -> (success: Bool, message: String) {
        guard let fund = fund(byId: fundId) else {
            return (false, "Fund not found")
        }
        do {
            _ = try await FundStore.shared.backupFund(id: fundId)
        } catch {
            return (false, "Backup failed: \(error.localizedDescription)")
        }

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

    /// Backup fund, interpolate missing values for a column, save to disk.
    func interpolateFundColumn(fundId: String, column: InterpolatableColumn) async -> (success: Bool, message: String) {
        guard let fund = fund(byId: fundId) else {
            return (false, "Fund not found")
        }
        // Backup first
        do {
            _ = try await FundStore.shared.backupFund(id: fundId)
        } catch {
            return (false, "Backup failed: \(error.localizedDescription)")
        }

        let entries = fund.entries
        let (updatedEntries, result) = await Task.detached(priority: .userInitiated) {
            interpolateColumn(column, entries: entries)
        }.value

        if result.interpolated > 0 {
            await replaceEntries(fundId: fundId, entries: updatedEntries)
        }
        return (true, "Interpolated \(result.interpolated) \(column.label) values (\(result.knownValues) known of \(result.totalEntries))")
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
        await recomputeWith(funds)
    }

    /// Per-fund metrics are cached by `(fundId, version)`. Funds whose version
    /// is unchanged since the last recompute reuse their cached metrics — so
    /// appending one entry to one fund only walks that fund's entries, not the
    /// entire portfolio's.
    private func recomputeWith(_ snapshot: [FundData]) async {
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

        // Update per-fund cache with fresh metrics, drop entries for vanished funds.
        for (j, entry) in stale.enumerated() {
            let (m, s) = result.freshMetrics[j]
            fundMetricsCache[entry.fundId] = CachedFundMetrics(version: entry.version, metrics: m, state: s)
        }
        let liveIds = Set(snapshot.map(\.id))
        fundMetricsCache = fundMetricsCache.filter { liveIds.contains($0.key) }

        // Apply funds + derived state atomically so the view never sees
        // new entries with stale summaries
        funds = snapshot
        portfolio = result.portfolio
        summaries = result.summaries
        summaryMap = result.summaryMap
        actionableFunds = result.actionableFunds
        platforms = result.platforms

        // Invalidate lazy audit cache
        _auditEntries = nil

        revision += 1
        updateDockBadge(actionableFunds.count)

        // Pre-compute chart data in background so fund detail pages load instantly
        ViewCache.shared.precomputeFundCharts(snapshot)

        // Debounce expensive side effects (notifications, Spotlight, widget)
        // so rapid recomputes during progressive load don't trigger them repeatedly
        sideEffectTask?.cancel()
        let currentFunds = funds
        sideEffectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await DCANotificationManager.shared.rescheduleAll()
            Task.detached { SpotlightIndexer.shared.indexFunds(currentFunds) }
            // Widget extension is iOS-only. On macOS, touching the iOS-style
            // (`group.*`) App Group container triggers the macOS 15 Sequoia
            // "would like to access data from other apps" TCC prompt for no
            // benefit, since nothing on macOS reads the snapshot.
            #if os(iOS)
            WidgetDataProvider.shared.updateSnapshot()
            #endif
        }
    }

    private var sideEffectTask: Task<Void, Never>?

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

    private func updateDockBadge(_ count: Int) {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #endif
    }
}
