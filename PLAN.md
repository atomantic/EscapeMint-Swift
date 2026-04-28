# EscapeMint Swift — Development Plan

For project context see [README.md](README.md) and [CLAUDE.md](CLAUDE.md).
For completed work see [DONE.md](DONE.md).

## Next Up

1. **Deepen service tests** — `AuthManager` has 4 happy-path tests but no lock-state-machine / keychain / biometric-flow coverage; `SpotlightIndexer` has crash-only smoke tests (no indexing assertions); `WidgetDataProvider.readSnapshot` has zero tests
2. **GuidedAddEntryView wizard tests** — added 2026-04-21 with zero coverage; extract step-transition + recommendation-recompute helpers; cover direct-equity / shares-price / exit-toggle branches
3. **AuthManager biometric pref → Keychain** — currently in `UserDefaults`, bypassable on jailbreak (use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
4. **Split `FundEngine.swift`** — 1371-line god file → TradeEngine / RecommendationEngine / PortfolioEngine
5. **Dynamic Type & adaptive colors** — 15× hardcoded 7-10pt fonts need `@ScaledMetric`; 8× `.foregroundColor(.white)` need adaptive variants

## Backlog

### Tests
- [ ] `FundStore` actor integration tests (785 lines, zero coverage)
- [ ] `FundDataStore` stateful in-memory tests (only `buildAuditEntries` tested)
- [ ] `ViewCache` cache lifecycle tests
- [ ] `BacktestEngine` edge cases — negative prices, zero dividends, volatile series exercising sells
- [ ] `importFromDirectory` parallel test (current `testBackupJSONSkipsTestFunds` only covers JSON path)
- [ ] `AdvancedTools.recalculateEntryPrices` price computation + zero-shares guard
- [ ] EngineTests weak assertions — nil recommendation non-default state, cash interest accuracy 5.0 → 0.10
- [ ] `WidgetDataProvider.readSnapshot` nil-path test
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

### Home Screen Widgets (WidgetKit)
Show portfolio value, daily gain/loss, next DCA action without opening the app. Small (value + change), Medium (top 3 with sparklines), Large (actionable funds list), Lock Screen widget. App Group container is already wired.

### Local Push Notifications for DCA Timing
Schedule per-fund notifications based on `last entry + interval_days`. "Time to DCA into BTC — $150 recommended". Reschedule on each new entry, deep-link tap to fund detail, badge = overdue count, settings toggle per-fund and global.

### Siri Shortcuts / App Intents
"What's my portfolio value?", "Show my top performer", morning portfolio summary. Spotlight indexing is already shipped — Siri integration via `AppIntent` remains.
