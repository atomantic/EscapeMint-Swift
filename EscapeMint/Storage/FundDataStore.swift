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

        // If iCloud wasn't available at init (e.g. after reboot), retry before loading
        if !FundStore.shared.isICloud {
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

        // Back on main actor — apply in batches with yields between them
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
            await recompute()
            // Yield to let the main run loop process UI events (button taps, scrolls)
            await Task.yield()
        }
    }

    // MARK: - Reload from Disk

    func reload() async {
        let loaded = await FundStore.shared.readAllFunds()
        funds = loaded
        loadedFundCount = loaded.count
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
            await recompute()
        }
        do {
            try await FundStore.shared.writeFund(fund)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("updateFund disk write failed: \(error)")
        }
    }

    func deleteFund(id: String) async {
        funds.removeAll { $0.id == id }
        loadedFundCount = funds.count
        await recompute()
        do {
            try await FundStore.shared.deleteFund(id: id)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("deleteFund disk delete failed: \(error)")
        }
    }

    func appendEntry(fundId: String, entry: FundEntry) async {
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].entries.append(entry)
            ViewCache.shared.invalidateFundCache(fundId: fundId)
            await recompute()
        }
        do {
            try await FundStore.shared.appendEntry(fundId: fundId, entry: entry)
            ICloudSyncMonitor.shared.markLocalWrite()
        } catch {
            Self.logger.error("appendEntry disk write failed: \(error)")
        }
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) async {
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].entries = entries
            ViewCache.shared.invalidateFundCache(fundId: fundId)
            await recompute()
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
            funds[idx].config = config
            await recompute()
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
    }

    private func recompute() async {
        let fundsSnapshot = funds

        // Run all expensive engine computation off the main thread
        let result = await Task.detached(priority: .userInitiated) {
            let portfolio = computePortfolioMetrics(fundsSnapshot)
            let summaries = computeSummariesFromPortfolio(funds: fundsSnapshot, portfolio: portfolio)
                .sorted { $0.currentValue > $1.currentValue }
            var map: [String: FundSummary] = [:]
            for s in summaries { map[s.fund.id] = s }
            let actionable = computeActionableFunds(fundsSnapshot)
            let platforms = Array(Set(fundsSnapshot.map(\.platform))).sorted()
            return ComputeResult(
                portfolio: portfolio,
                summaries: summaries,
                summaryMap: map,
                actionableFunds: actionable,
                platforms: platforms
            )
        }.value

        // Apply results on main thread (cheap assignment)
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
        ViewCache.shared.precomputeFundCharts(fundsSnapshot)

        // Debounce expensive side effects (notifications, Spotlight, widget)
        // so rapid recomputes during progressive load don't trigger them repeatedly
        sideEffectTask?.cancel()
        let currentFunds = funds
        sideEffectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await DCANotificationManager.shared.rescheduleAll()
            Task.detached { SpotlightIndexer.shared.indexFunds(currentFunds) }
            WidgetDataProvider.shared.updateSnapshot()
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
