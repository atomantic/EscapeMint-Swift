import Foundation
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

    /// 0.0 to 1.0 — tracks how many funds have their entries loaded
    private(set) var loadProgress: Double = 0
    private(set) var loadedFundCount: Int = 0
    private(set) var totalFundCount: Int = 0

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
    private var _auditFundsSnapshot: [FundData]?
    var auditEntries: [AuditEntry] {
        if let cached = _auditEntries { return cached }
        let entries = Self.buildAuditEntries(from: funds)
        _auditEntries = entries
        _auditFundsSnapshot = funds
        return entries
    }

    private init() {}

    // MARK: - Initial Load (Progressive)

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await FundStore.shared.migrateToICloudIfNeeded()

        // Phase 1: Load configs only (instant — just JSON files, no TSV parsing)
        let configs = await FundStore.shared.readAllFundConfigs()
        funds = configs
        totalFundCount = configs.count
        loadedFundCount = 0
        loadProgress = configs.isEmpty ? 1.0 : 0.0
        platforms = Array(Set(configs.map(\.platform))).sorted()
        isConfigLoaded = true

        if configs.isEmpty {
            isLoaded = true
            return
        }

        // Phase 2: Stream entries in parallel, recompute in batches
        await loadEntriesProgressively()
        isLoaded = true
    }

    /// Load TSV entries concurrently, updating the store in batches for smooth progress
    private func loadEntriesProgressively() async {
        let fundIds = funds.map(\.id)
        let batchSize = max(1, fundIds.count / 5) // ~5 progress updates

        // Load entries concurrently using a task group
        let allEntries: [(String, [FundEntry])] = await withTaskGroup(of: (String, [FundEntry]).self) { group in
            for id in fundIds {
                group.addTask {
                    let entries = await FundStore.shared.readFundEntries(id: id)
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

        // Apply entries in batches for progressive UI updates
        var applied = 0
        for (id, entries) in allEntries {
            if let idx = funds.firstIndex(where: { $0.id == id }) {
                funds[idx].entries = entries
            }
            applied += 1
            loadedFundCount = applied
            loadProgress = Double(applied) / Double(totalFundCount)

            // Recompute at batch boundaries and on the final fund
            if applied % batchSize == 0 || applied == totalFundCount {
                await recompute()
            }
        }
    }

    // MARK: - Reload from Disk

    func reload() async {
        let loaded = await FundStore.shared.readAllFunds()
        funds = loaded
        totalFundCount = loaded.count
        loadedFundCount = loaded.count
        loadProgress = 1.0
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

    // MARK: - Mutations (update memory + disk)

    func addFund(_ fund: FundData) async {
        try? await FundStore.shared.writeFund(fund)
        funds.append(fund)
        totalFundCount = funds.count
        loadedFundCount = funds.count
        await recompute()
    }

    func updateFund(_ fund: FundData) async {
        try? await FundStore.shared.writeFund(fund)
        if let idx = funds.firstIndex(where: { $0.id == fund.id }) {
            funds[idx] = fund
        }
        await recompute()
    }

    func deleteFund(id: String) async {
        try? await FundStore.shared.deleteFund(id: id)
        funds.removeAll { $0.id == id }
        totalFundCount = funds.count
        loadedFundCount = funds.count
        await recompute()
    }

    func appendEntry(fundId: String, entry: FundEntry) async {
        try? await FundStore.shared.appendEntry(fundId: fundId, entry: entry)
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].entries.append(entry)
            await recompute()
        }
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) async {
        try? await FundStore.shared.replaceEntries(fundId: fundId, entries: entries)
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].entries = entries
            await recompute()
        }
    }

    func updateConfig(fundId: String, config: FundConfig) async {
        try? await FundStore.shared.updateConfig(fundId: fundId, config: config)
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].config = config
            await recompute()
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

    private func updateDockBadge(_ count: Int) {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #endif
    }
}
