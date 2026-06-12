import Foundation
import SwiftUI

/// Holds the shared historical price bundle and the backtest screen's persistent
/// state (config/preset/range/sort/result/task). NavigationSplitView destroys and
/// recreates detail views, so keeping this here lets the backtest survive navigation
/// and lets the intro guide read the same historical data without reloading it.
///
/// `@MainActor`-isolated: every property is read and mutated on the main actor, which
/// is what lets the off-actor compute tasks below hand their results back safely
/// (see the #42 audit note on the main-actor invariant).
@MainActor @Observable
final class BacktestCache {
    static let shared = BacktestCache()

    private init() {}

    /// Start loading historical data. Call early at app launch.
    /// Priority is boosted for first-time users (guide needs backtest data ASAP).
    func startLoading(prioritizeGuide: Bool = false) {
        guard _historicalData == nil, !_loadingStarted else { return }
        _loadingStarted = true
        let priority: TaskPriority = prioritizeGuide ? .userInitiated : .utility
        _loadingTask = Task {
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
    private var _loadingTask: Task<Void, Never>?

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
}
