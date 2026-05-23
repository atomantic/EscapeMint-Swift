# EscapeMint Swift — Development Plan

For project context see [README.md](README.md) and [CLAUDE.md](CLAUDE.md).
For completed work see [DONE.md](DONE.md).

## Next Up

1. **Deepen service tests** — `AuthManager` has 4 happy-path tests but no lock-state-machine / keychain / biometric-flow coverage; `SpotlightIndexer` has crash-only smoke tests (no indexing assertions)
2. **GuidedAddEntryView wizard tests** — added 2026-04-21 with zero coverage; extract step-transition + recommendation-recompute helpers; cover direct-equity / shares-price / exit-toggle branches
3. **AuthManager biometric pref → Keychain** — currently in `UserDefaults`, bypassable on jailbreak (use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
4. **Split `FundEngine.swift`** — 1371-line god file → TradeEngine / RecommendationEngine / PortfolioEngine
5. **Dynamic Type & adaptive colors** — 15× hardcoded 7-10pt fonts need `@ScaledMetric`; 8× `.foregroundColor(.white)` need adaptive variants

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
