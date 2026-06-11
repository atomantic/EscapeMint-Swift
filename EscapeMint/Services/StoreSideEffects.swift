import Foundation

/// Owns the post-recompute side effects that used to live inside `FundDataStore`:
/// background chart precompute (ViewCache) and the debounced services fan-out
/// (DCA notifications, Spotlight, widget snapshot). Keeping these here means the
/// Storage layer no longer imports Services or the presentation cache, and tests
/// that drive recompute directly never fire notification/Spotlight/widget effects.
@MainActor
final class StoreSideEffects {
    static let shared = StoreSideEffects()

    private var sideEffectTask: Task<Void, Never>?

    private init() {}

    /// React to a recompute: kick off chart precompute immediately and (re)arm the
    /// 2s-debounced services fan-out, cancelling any in-flight debounce. Mirrors the
    /// behavior that previously lived at the tail of `FundDataStore.recomputeWith`.
    func onRecompute(_ context: FundDataStore.RecomputeContext) {
        let funds = context.funds

        // Pre-compute chart data in background so fund detail pages load instantly.
        ViewCache.shared.precomputeFundCharts(funds)

        // Debounce expensive side effects (notifications, Spotlight, widget) so rapid
        // recomputes during progressive load don't trigger them repeatedly.
        sideEffectTask?.cancel()
        sideEffectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await DCANotificationManager.shared.rescheduleAll()
            Task.detached { SpotlightIndexer.shared.indexFunds(funds) }
            // Widget extension is iOS-only. On macOS, touching the iOS-style
            // (`group.*`) App Group container triggers the macOS 15 Sequoia
            // "would like to access data from other apps" TCC prompt for no
            // benefit, since nothing on macOS reads the snapshot.
            #if os(iOS)
            WidgetDataProvider.shared.updateSnapshot()
            #endif
        }
    }
}

extension FundDataStore {
    /// Wire up the app's standard post-recompute side effects. Called once from
    /// `loadIfNeeded` (via `bootstrapRecomputeObserversIfNeeded`).
    func registerDefaultRecomputeObservers() {
        addRecomputeObserver { context in
            StoreSideEffects.shared.onRecompute(context)
        }
        addFundInvalidationObserver { fundId in
            ViewCache.shared.invalidateFundCache(fundId: fundId)
        }
        #if os(macOS)
        addRecomputeObserver { context in
            StoreDockBadge.update(actionableCount: context.actionableCount)
        }
        #endif
    }
}
