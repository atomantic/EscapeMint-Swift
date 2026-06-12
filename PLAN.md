# EscapeMint Swift — Development Plan

For project context see [README.md](README.md) and [CLAUDE.md](CLAUDE.md).
For completed work see [DONE.md](DONE.md).

> **2026-06-11 better-swift audit — COMPLETE.** All 38 findings (#10–#47) were filed as `plan`-labeled issues, remediated across 12 PRs (#48–#59), and merged to `main`; both iOS and macOS build clean with 330 passing tests. The earlier "Next Up" list is now substantially closed by that pass: CI scheme fix (#10/#48), biometric flag → Keychain (#19/#49), `FundEngine` split (#44/#56), pure engine extraction out of views (#12–#16/#51), Dynamic Type / sub-legible fonts (#21,#24/#52), engine+storage test coverage (#33–#40/#54). See closed issues for the full record.

## Next Up

Small follow-ups surfaced during the audit (intentionally scoped out of their PRs to avoid cross-branch churn):

1. **`isWide` dedup** — a 5-line `private var isWide` wrapper still repeats in `BacktestView`, `DashboardView`, `BacktestCharts`, `BacktestConfigPanel`. A real fix unguards `horizontalSizeClass` on macOS (always `.regular`) so one shared `View.isWide` extension can replace all four.
2. **Typed NotificationCenter helpers — finish adoption** — `postSelectFund(id:)`/`postSelectPlatform(name:)`/`postShowAddEntry(id:)` exist now; remaining `note.object as? String` post/observe sites (`EscapeMintApp`, `DCANotificationManager`, `PlatformDetailView`, `IntroGuideView`, `ActionableFundsBanner`, `AuditTrailView`) should adopt them.
3. **Remaining Dynamic Type stragglers** — `LockScreenView` 48pt icon and `AddEntryView` macOS `minHeight: 380` were outside the font-fix PR's ownership; convert to `@ScaledMetric` / a taller min for trading funds.
4. **Testability seams** — `WidgetDataProvider.readSnapshot()` and `SpotlightIndexer` still lack injection points to assert their side effects (flagged by the test pass). `FundStore` now has an injectable directory resolver (#47) — extend the same pattern.
5. **Adaptive colors** — 8× `.foregroundColor(.white)` still need dark-mode-aware variants (not covered by the audit's font work).

## Backlog

### Tests
- [ ] `FundStore` concurrent-actor-access stress (StorageTests covers methods individually; no overlap-write tests)
- [ ] `FundDataStore` stateful coverage beyond `buildAuditEntries` / `applyRenames` (mutation paths, summary recompute, error toasts)
- [ ] `DCANotificationManager` — schedule/reschedule correctness, permission denial path (only `cancelAll` idempotency tested)
- [x] `ViewCache` cache lifecycle tests — covered by `ViewCacheTests.swift`
- [ ] `BacktestEngine` edge cases — negative prices, zero dividends
- [x] `BacktestEngine` volatile series exercising sells — covered by `testRunBacktestVolatileMarketTriggersSells`
- [x] `AdvancedTools.recalculateEntryPrices` price computation + zero-shares guard — covered by `AdvancedToolsTests`
- [ ] EngineTests weak assertions — nil recommendation non-default state, cash interest accuracy 5.0 → 0.10
- [x] `WidgetDataProvider.readSnapshot` nil-path / no-crash coverage — covered by `ServicesTests`
- [ ] Converters concurrent holiday-cache stress test (validates `OSAllocatedUnfairLock` under load)
- [ ] TSV malformed-input edge cases (extra tabs, missing columns)

### Architecture
- [ ] `DashboardView` / `SettingsView` → route through `FundDataStore` (currently call `FundStore.shared` directly; DashboardView:622, SettingsView:197/304-419)
- [ ] `FundDataStore` inject `FundStore` via protocol (singleton-coupled today)
- [ ] `importFromBackupJSON` → Codable `BackupDocument` (replace `JSONSerialization`)
- [ ] `ViewCache` split (backtest state vs chart caches) + typed dicts to drop `@unchecked Sendable<Any>`
- [ ] Move `computePortfolioTimeSeries` / `compute*Points` logic from views into Engine
- [ ] `FundDetailView.task` business logic → ViewModel

### Performance
- [ ] `FundCharts.computePLPoints` / `computeAPYPoints` O(n²) → incremental cursor
- [ ] `PortfolioCharts.swift:456` dictionary grouping inside `ForEach` — compute once
- [ ] `MacContentView` body recomputes `activeFunds` every render — read from `store.summaries`

### DRY
- [ ] Derivatives entry-processing switch duplicated 3× (FundEngine metrics, FundEngine entry rows, DerivativesCharts) — extract shared accumulator
- [ ] `BacktestCharts.ChartCardModifier` → reconcile with `Theme.CardStyle` (parameterize)
- [ ] FundCharts/DerivativesCharts: replace 15× `isoDateFormatter.date(from: pt.date) ?? Date()` with `pt.dateValue`
- [ ] `DerivativesCharts` inline leverage axis → extract `emLeverageAxis()`
- [ ] `IntroCharts` axis builders → reuse shared functions
- [ ] `StatBox` / `MetricCard` consolidation in FundCharts
- [ ] Move scattered chart color palettes into `Theme.swift`
- [ ] `PortfolioCharts` hardcoded chart height 150 (8 instances) → `Layout.dashboardChartHeight`

### Platform & Polish
- [ ] `withAnimation` in MacContentView/DashboardView collapse — guard with `accessibilityReduceMotion`
- [ ] iOS 26 liquid glass TabView appearance polish (using traditional `tabItem` API today)
- [ ] Backtest date-range TextField → DatePicker bound to `Date`
- [ ] Add `#Preview` macros to major views (good first-contributor task)
- [ ] Info.plist / project.yml cleanup — `GENERATE_INFOPLIST_FILE`, `UILaunchScreen` duplication, iPhone orientation list

### Open-Source Hygiene
- [ ] `SECURITY.md` — vulnerability disclosure policy, scope (no external auth, local-only biometric, App Group data on-device)

## Future / Ideas

### Siri Shortcuts / App Intents
"What's my portfolio value?", "Show my top performer", morning portfolio summary. Spotlight indexing is already shipped — Siri integration via `AppIntent` remains.
