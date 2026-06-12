import Foundation
import SwiftUI

/// Caches expensive chart/table computations that would otherwise be lost when
/// NavigationSplitView destroys and recreates detail views. Covers the dashboard
/// time series plus the per-fund detail artifacts (entry rows, derivatives points,
/// and line-chart series). Invalidated only when the underlying data changes.
///
/// `@MainActor`-isolated: all storage is read and written on the main actor, which is
/// what lets the off-actor compute tasks below hand their results back without data
/// races (see the #42 audit note on the main-actor invariant). Because the cache never
/// escapes the main actor, the stored value types need no `Sendable` conformance.
@MainActor @Observable
final class ChartCache {
    static let shared = ChartCache()
    static let maxCachedFunds = 10

    private init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearNonEssentialCaches() }
        }
        #endif
    }

    /// Clear chart and row caches on memory pressure (historical data is kept by `BacktestCache`)
    func clearNonEssentialCaches() {
        chartPointsCache.removeAll()
        fundRowsCache.removeAll()
        fundDerivCache.removeAll()
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
            // Coalesce rapid store revisions from entry edits/imports so chart
            // rebuilding does not compete with button taps and text entry.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
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

    /// Typed storage for the per-fund line-chart series. Replaces the old `Any`-erased
    /// wrapper: each case holds the concrete point array for one of the four fund-detail
    /// charts, so a read can never misinterpret a blob and no `@unchecked Sendable`
    /// escape hatch is needed. The generic `cacheChartPoints` / `cachedChartPoints`
    /// accessors below bridge the generic `FundCharts` call site to these cases.
    private enum CachedChartPoints {
        case value([ValuePoint])
        case pl([PLPoint])
        case apy([APYPoint])
        case profit([ProfitPoint])

        /// Map a concrete point array to its case, or nil for an unsupported type.
        static func wrap<T>(_ points: [T]) -> CachedChartPoints? {
            switch points {
            case let p as [ValuePoint]: return .value(p)
            case let p as [PLPoint]: return .pl(p)
            case let p as [APYPoint]: return .apy(p)
            case let p as [ProfitPoint]: return .profit(p)
            default: return nil
            }
        }

        /// Extract the stored array as `[T]`, or nil if the requested type differs.
        func unwrap<T>(as _: T.Type) -> [T]? {
            switch self {
            case .value(let p): return p as? [T]
            case .pl(let p): return p as? [T]
            case .apy(let p): return p as? [T]
            case .profit(let p): return p as? [T]
            }
        }
    }

    /// Chart points cache keyed by "\(TypeName)-\(fundId)-\(entryCount)"
    private var chartPointsCache: [String: CachedChartPoints] = [:]

    func cachedChartPoints<T>(type: T.Type, fundId: String, entryCount: Int) -> [T]? {
        chartPointsCache["\(T.self)-\(fundCacheKey(fundId, entryCount: entryCount))"]?.unwrap(as: T.self)
    }

    func cacheChartPoints<T>(_ points: [T], type: T.Type, fundId: String, entryCount: Int) {
        guard let entry = CachedChartPoints.wrap(points) else { return }
        chartPointsCache["\(T.self)-\(fundCacheKey(fundId, entryCount: entryCount))"] = entry
    }

    func invalidateFundCache(fundId: String) {
        for key in fundRowsCache.keys where key.hasPrefix(fundId) { fundRowsCache.removeValue(forKey: key) }
        for key in fundDerivCache.keys where key.hasPrefix(fundId) { fundDerivCache.removeValue(forKey: key) }
        for key in chartPointsCache.keys where key.contains(fundId) { chartPointsCache.removeValue(forKey: key) }
    }

    // MARK: - Background Pre-computation

    private var precomputeTask: Task<Void, Never>?

    /// Pre-compute only the shared row/derivatives data in the background.
    /// Eagerly building every chart for every fund makes visible chart tasks
    /// compete with off-screen work, which can leave fund detail charts sitting
    /// on their loading placeholders for large portfolios.
    func precomputeFundCharts(_ funds: [FundData]) {
        precomputeTask?.cancel()
        precomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            for fund in funds {
                guard !Task.isCancelled else { return }
                let fid = fund.id
                let ec = fund.entries.count
                guard ec >= 3 else { continue }
                let entries = fund.entries
                let config = fund.config

                if cachedRows(fundId: fid, entryCount: ec) == nil {
                    let rows = await bgCompute { computeEntryRows(entries: entries, config: config) }
                    guard !Task.isCancelled else { return }
                    cacheRows(rows, fundId: fid, entryCount: ec)
                }

                if config.fund_type == .derivatives, cachedDerivPoints(fundId: fid, entryCount: ec) == nil {
                    let pts = await bgCompute { computeDerivativesChartData(entries: entries, config: config) }
                    guard !Task.isCancelled else { return }
                    cacheDerivPoints(pts, fundId: fid, entryCount: ec)
                }
                await Task.yield()
            }
        }
    }

    /// Run a computation on a background thread
    private func bgCompute<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .background) { work() }.value
    }
}
