import Foundation
import SwiftUI

/// Shared in-memory cache for all fund data. Loads once from disk at startup,
/// then serves all views instantly. Mutations update memory + disk together.
@MainActor @Observable
final class FundDataStore {
    static let shared = FundDataStore()

    private(set) var funds: [FundData] = []
    private(set) var isLoaded = false

    /// Incremented on every recompute — views can observe this to invalidate caches
    private(set) var revision: Int = 0

    // Pre-computed derived state (updated on every refresh)
    private(set) var portfolio = PortfolioMetrics()
    private(set) var summaries: [FundSummary] = []
    private(set) var summaryMap: [String: FundSummary] = [:]
    private(set) var actionableFunds: [ActionableFund] = []
    private(set) var auditEntries: [AuditEntry] = []
    private(set) var platforms: [String] = []

    private init() {}

    // MARK: - Initial Load

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await FundStore.shared.migrateToICloudIfNeeded()
        await reload()
        isLoaded = true
    }

    // MARK: - Reload from Disk

    func reload() async {
        let loaded = await FundStore.shared.readAllFunds()
        funds = loaded
        recompute()
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
        recompute()
    }

    func updateFund(_ fund: FundData) async {
        try? await FundStore.shared.writeFund(fund)
        if let idx = funds.firstIndex(where: { $0.id == fund.id }) {
            funds[idx] = fund
        }
        recompute()
    }

    func deleteFund(id: String) async {
        try? await FundStore.shared.deleteFund(id: id)
        funds.removeAll { $0.id == id }
        recompute()
    }

    func appendEntry(fundId: String, entry: FundEntry) async {
        try? await FundStore.shared.appendEntry(fundId: fundId, entry: entry)
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].entries.append(entry)
            recompute()
        }
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) async {
        try? await FundStore.shared.replaceEntries(fundId: fundId, entries: entries)
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].entries = entries
            recompute()
        }
    }

    func updateConfig(fundId: String, config: FundConfig) async {
        try? await FundStore.shared.updateConfig(fundId: fundId, config: config)
        if let idx = funds.firstIndex(where: { $0.id == fundId }) {
            funds[idx].config = config
            recompute()
        }
    }

    // MARK: - Recompute Derived State

    private func recompute() {
        portfolio = computePortfolioMetrics(funds)
        summaries = computeSummariesFromPortfolio(funds: funds, portfolio: portfolio)
            .sorted { $0.currentValue > $1.currentValue }
        var map: [String: FundSummary] = [:]
        for s in summaries { map[s.fund.id] = s }
        summaryMap = map
        actionableFunds = computeActionableFunds(funds)
        platforms = Array(Set(funds.map(\.platform))).sorted()

        // Pre-compute audit entries so AuditTrailView doesn't rebuild on every render
        var entries: [AuditEntry] = []
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
        auditEntries = entries.sorted { $0.date > $1.date }

        revision += 1
        updateDockBadge(actionableFunds.count)
    }

    private func updateDockBadge(_ count: Int) {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #endif
    }
}
