import Foundation
import SwiftUI

/// Caches expensive view computations that would otherwise be lost when NavigationSplitView
/// destroys and recreates detail views. Invalidated only when the underlying data changes.
@MainActor @Observable
final class ViewCache {
    static let shared = ViewCache()
    private init() {}

    /// Start loading historical data. Call early at app launch.
    /// Priority is boosted for first-time users (guide needs backtest data ASAP).
    func startLoading(prioritizeGuide: Bool = false) {
        guard _historicalData == nil, !_loadingStarted else { return }
        _loadingStarted = true
        let priority: TaskPriority = prioritizeGuide ? .userInitiated : .utility
        Task {
            let data = await Task.detached(priority: priority) {
                loadHistoricalData()
            }.value
            _historicalData = data
            if prioritizeGuide {
                ModeComparisonPreloader.shared.onHistoricalDataLoaded()
            }
        }
    }

    private var _loadingStarted = false

    // MARK: - Historical Data (static bundle data, loaded once)

    private var _historicalData: [String: HistoricalData]?
    var isHistoricalDataLoaded: Bool { _historicalData != nil }
    var historicalData: [String: HistoricalData] { _historicalData ?? [:] }

    // MARK: - Backtest

    private var lastBacktestConfig: BacktestConfig?
    private var lastBacktestDateRange: BacktestDateRange?
    private(set) var backtestResult: BacktestResult?
    private(set) var backtestDateRange: BacktestDateRange?
    private(set) var backtestAvailableRange: BacktestDateRange?
    private(set) var backtestConfig = BacktestConfig()
    private(set) var backtestPreset: BacktestPreset = .blend
    private(set) var backtestSortOrder: BacktestSortOrder = .asc
    private(set) var isRunningBacktest = false
    private var backtestTask: Task<Void, Never>?

    enum BacktestSortOrder {
        case asc, desc
    }

    func updateBacktestConfig(_ config: BacktestConfig) {
        backtestConfig = config
    }

    func updateBacktestPreset(_ preset: BacktestPreset) {
        backtestPreset = preset
    }

    func updateBacktestSortOrder(_ order: BacktestSortOrder) {
        backtestSortOrder = order
    }

    func updateBacktestDateRange(_ range: BacktestDateRange?) {
        backtestDateRange = range
    }

    func updateAvailableRange() {
        guard isHistoricalDataLoaded else { return }
        backtestAvailableRange = computeAvailableDateRange(
            historicalData: historicalData,
            allocations: backtestConfig.allocations
        )
        if backtestDateRange == nil {
            backtestDateRange = backtestAvailableRange
        }
    }

    func runBacktestIfNeeded() {
        updateAvailableRange()
        let config = backtestConfig
        let dr = backtestDateRange
        // Skip if already computed for identical inputs
        if config == lastBacktestConfig && dr == lastBacktestDateRange && backtestResult != nil { return }
        guard isHistoricalDataLoaded else { return }

        if let old = backtestTask {
            old.cancel()
            backtestTask = nil
        }
        isRunningBacktest = true
        let hist = historicalData
        lastBacktestConfig = config
        lastBacktestDateRange = dr
        backtestTask = Task {
            let r = await Task.detached(priority: .userInitiated) {
                runBacktest(config: config, historicalData: hist, dateRange: dr)
            }.value
            guard !Task.isCancelled else { return }
            backtestResult = r
            isRunningBacktest = false
        }
    }

    // MARK: - Dashboard Time Series

    private var dashboardRevision: Int = -1
    private(set) var dashboardTimeSeries: [PortfolioTimeSeriesPoint] = []
    private(set) var isComputingDashboard = false
    private var dashboardTask: Task<Void, Never>?

    var hasDashboardCache: Bool { !dashboardTimeSeries.isEmpty }

    func isDashboardCacheValid(revision: Int) -> Bool {
        revision == dashboardRevision
    }

    func recomputeDashboardTimeSeries(funds: [FundData], revision: Int) {
        guard revision != dashboardRevision else { return }
        dashboardTask?.cancel()
        isComputingDashboard = true
        dashboardTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                computePortfolioTimeSeries(funds)
            }.value
            guard !Task.isCancelled else { return }
            dashboardTimeSeries = result
            dashboardRevision = revision
            isComputingDashboard = false
        }
    }

    func cancelDashboard() {
        dashboardTask?.cancel()
        dashboardTask = nil
        isComputingDashboard = false
        dashboardTimeSeries = []
        dashboardRevision = -1
    }

    // MARK: - Fund Detail

    /// Cache for per-fund computed entry rows (keyed by fundId-entryCount)
    private var fundRowsCache: [String: [ComputedEntryRow]] = [:]
    private var fundDerivCache: [String: [DerivativesChartPoint]] = [:]

    func fundCacheKey(_ fundId: String, entryCount: Int) -> String {
        "\(fundId)-\(entryCount)"
    }

    func cachedRows(fundId: String, entryCount: Int) -> [ComputedEntryRow]? {
        fundRowsCache[fundCacheKey(fundId, entryCount: entryCount)]
    }

    func cacheRows(_ rows: [ComputedEntryRow], fundId: String, entryCount: Int) {
        fundRowsCache[fundCacheKey(fundId, entryCount: entryCount)] = rows
    }

    func cachedDerivPoints(fundId: String, entryCount: Int) -> [DerivativesChartPoint]? {
        fundDerivCache[fundCacheKey(fundId, entryCount: entryCount)]
    }

    func cacheDerivPoints(_ points: [DerivativesChartPoint]?, fundId: String, entryCount: Int) {
        let key = fundCacheKey(fundId, entryCount: entryCount)
        if let points {
            fundDerivCache[key] = points
        } else {
            fundDerivCache.removeValue(forKey: key)
        }
    }

    /// Type-erased wrapper for chart point arrays
    private struct ChartCacheEntry: @unchecked Sendable {
        let value: Any
        func unwrap<T>(as _: T.Type) -> [T]? { value as? [T] }
    }

    /// Type-safe chart points cache keyed by "\(TypeName)-\(fundId)-\(entryCount)"
    private var chartPointsCache: [String: ChartCacheEntry] = [:]

    func cachedChartPoints<T>(type: T.Type, fundId: String, entryCount: Int) -> [T]? {
        chartPointsCache["\(T.self)-\(fundCacheKey(fundId, entryCount: entryCount))"]?.unwrap(as: T.self)
    }

    func cacheChartPoints<T>(_ points: [T], type: T.Type, fundId: String, entryCount: Int) {
        chartPointsCache["\(T.self)-\(fundCacheKey(fundId, entryCount: entryCount))"] = ChartCacheEntry(value: points)
    }

    func invalidateFundCache(fundId: String) {
        for key in fundRowsCache.keys where key.hasPrefix(fundId) { fundRowsCache.removeValue(forKey: key) }
        for key in fundDerivCache.keys where key.hasPrefix(fundId) { fundDerivCache.removeValue(forKey: key) }
        for key in chartPointsCache.keys where key.contains(fundId) { chartPointsCache.removeValue(forKey: key) }
    }
}
