import Foundation

/// Orchestrates the off-main-thread computation of fund-detail entry rows and
/// derivatives chart points, caching the results in `ChartCache`.
///
/// This keeps `FundDetailView`'s body declarative: the view drives this with a
/// single `.task(id:)`, and all the "is it cached? compute it, then cache it"
/// bookkeeping lives here where it can be unit-tested without a view. The engine
/// functions (`computeEntryRows`, `computeDerivativesChartData`) remain pure;
/// this type only sequences them and writes their output into the cache.
@MainActor @Observable
final class FundDetailViewModel {
    private let cache: ChartCache

    init(cache: ChartCache = .shared) {
        self.cache = cache
    }

    /// Compute and cache the entry rows and (for derivatives funds) chart points
    /// for the given fund, skipping any artifact that's already cached for this
    /// entry count. Heavy work runs on a detached background task; the method is
    /// cancellation-aware so a fund switch or data change abandons stale work.
    func loadComputedData(fundId: String, entries: [FundEntry], config: FundConfig) async {
        let entryCount = entries.count

        // Compute entry rows off the main thread (if not already cached).
        if cache.cachedRows(fundId: fundId, entryCount: entryCount) == nil {
            let rows = await Task.detached(priority: .userInitiated) {
                computeEntryRows(entries: entries, config: config)
            }.value
            guard !Task.isCancelled else { return }
            cache.cacheRows(rows, fundId: fundId, entryCount: entryCount)
        }

        if config.fund_type == .derivatives {
            if cache.cachedDerivPoints(fundId: fundId, entryCount: entryCount) == nil {
                let points = await Task.detached(priority: .userInitiated) {
                    computeDerivativesChartData(entries: entries, config: config)
                }.value
                guard !Task.isCancelled else { return }
                cache.cacheDerivPoints(points, fundId: fundId, entryCount: entryCount)
            }
        } else {
            // Clear any stale derivatives points if the fund was reclassified.
            cache.cacheDerivPoints(nil, fundId: fundId, entryCount: entryCount)
        }
    }
}
