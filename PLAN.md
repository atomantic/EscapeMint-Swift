# EscapeMint Swift — Development Plan

Native SwiftUI app for iOS, iPadOS, and macOS. Same bundle ID as the App Store Connect listing (`net.shadowpuppet.EscapeMint`).

## Next Actions

1. **Phase 2: iPhone/iPad Adaptation** — adapt macOS layouts for smaller screens (see below)
2. **Phase 3: iCloud Sync** — cross-device sync via iCloud Documents
3. **Phase 4: Polish & Submission** — screenshots, App Store review
4. **Test coverage** — address deferred test quality findings from audits

## High-Impact Feature Ideas

### 1. Home Screen Widgets (WidgetKit)
Show portfolio value, daily gain/loss %, and next DCA action at a glance without opening the app. Finance apps live or die by how quickly users can check their numbers — widgets make that instant.
- **Small widget**: Total portfolio value + daily change (green/red)
- **Medium widget**: Top 3 funds by value with sparkline mini-charts
- **Large widget**: Actionable funds list (which funds need a BUY/DEPOSIT today)
- **Lock Screen widget**: Portfolio value + % change
- Timeline refresh on fund data changes via `WidgetCenter.shared.reloadAllTimelines()`
- Shared data via App Group container (FundStore writes summary JSON for widget to read)

### 2. Local Push Notifications for DCA Timing
The app already computes `interval_days` per fund and knows exactly when the next DCA action is due — surface that as scheduled local notifications so users never miss a buy window. Zero server infrastructure needed.
- Schedule `UNNotificationRequest` per fund based on last entry date + interval_days
- "Time to DCA into BTC — $150 recommended" with fund-specific amounts from the recommendation engine
- Reschedule on each new entry (entry added = timer resets)
- Settings toggle per-fund and global on/off
- Deep link notification tap → fund detail view
- Badge count = number of overdue DCA actions (already computed for dock badge)

### 3. Live Price Integration (CoinGecko / Yahoo Finance)
Transform from manual-entry tracking to live portfolio valuation. Currently users only see values as of their last entry — live prices would show real-time portfolio value and unrealized gain/loss between entries.
- Free tier APIs: CoinGecko (crypto, no key needed), Yahoo Finance (stocks)
- Map fund tickers to API symbols (BTC→bitcoin, AAPL→AAPL)
- Show live price + change on dashboard cards and fund detail header
- Compute real-time unrealized P&L: `(livePrice - lastEntryPrice) * shares`
- Cache prices locally with 5-min TTL to stay within rate limits
- Optional — doesn't replace manual entries, just enriches between-entry visibility
- Graceful degradation: works fully offline with last-cached prices

### 4. Biometric Authentication (Face ID / Touch ID)
Financial data is sensitive — a biometric lock is table stakes for any finance app on the App Store. Users expect it and reviewers look for it.
- `LAContext` with `.deviceOwnerAuthenticationWithBiometrics` on app foreground
- Fallback to device passcode
- Settings toggle: "Require Face ID / Touch ID"
- Blur/hide content in app switcher (`.privacySensitive()` or overlay in `scenePhase == .inactive`)
- `@AppStorage` flag — no server, no accounts, just local biometric gate
- Minimal code (~50 lines for the auth manager + a gate view)

### 5. Spotlight Search & Siri Shortcuts
Let users find funds instantly from the iOS home screen and ask Siri for portfolio status — makes the app feel like a first-class citizen on the platform.
- **Spotlight**: Index funds via `CSSearchableIndex` — search "BTC" or "Coinbase" from home screen, deep link to fund detail
- Update index on fund create/delete/rename
- **Siri Shortcuts**: Donate `INInteraction` for common actions
  - "What's my portfolio value?" → spoken response with total value + daily change
  - "Show my top performer" → opens fund detail for highest-gain fund
  - Shortcuts app integration for automation (e.g., morning portfolio summary)
- **App Intents** (iOS 16+): `AppIntent` protocol for type-safe Siri integration
- Low effort, high perceived quality — signals a polished, native app

## Known Issues

- [ ] iOS 26 liquid glass TabView — using traditional `tabItem` API instead, but appearance still not ideal
- [x] ~~DRY: identical `calcPriceEquity()` in AddEntryView + EditEntryView~~ — extracted to `EntryFormHelpers.swift`
- [ ] Architecture: DashboardView:622 direct FundStore access for import (needs FundDataStore wrapper)
- [x] ~~Dashboard metric values differ from webapp~~ — fixed: derivatives fund metrics, portfolioDays, endDate, fundSize
- [ ] DRY: derivatives entry-processing switch duplicated 3x (FundEngine metrics, FundEngine entry rows, DerivativesCharts) — extract shared accumulator

### Deferred Test Quality Findings

- [ ] Weak assertion patterns in EngineTests (XCTAssertNotNil + force unwrap, try!, re-implemented logic, loose accuracy)
- [ ] Missing test coverage: FundStore actor, FundDataStore, import/export, computeFundSizeForEntry, FundEntry Codable round-trips
- [ ] Missing edge case tests: BacktestEngine (negative prices, zero dividends), FundEngine (margin/derivatives)

---

## Better Swift Audit - 2026-04-07

Summary: 99 findings across 7 categories. 6 CRITICAL, 27 HIGH, 40 MEDIUM, 26 LOW.
Platforms: iOS 17+, macOS 14+ | Build system: XcodeGen
Gotcha catalogue entries in scope: #4 (iCloud ubiquity), #5 (iCloud symlink), #7 (XcodeGen), #8 (TestFlight upload), #9 (App Group provisioning), #11 (foregroundStyle(.accentColor))

### Remediated — 4 per-category PRs open against main
- atomantic/EscapeMint-Swift#3 — **security**: WidgetDataProvider file protection, SpotlightIndexer/DCANotificationManager PII removal, AppStorageKeys centralization
- atomantic/EscapeMint-Swift#4 — **platform-swiftui**: deploy.sh altool guard + build-number rollback trap, macOS App Group entitlement, LockScreenView `.task`
- atomantic/EscapeMint-Swift#5 — **bugs-perf + architecture + dry**: FundStore directory-state `OSAllocatedUnfairLock`, Formatters/Converters thread-safe caches, stable FundEntry.id, FundStore error propagation + file protection, EMChartLoadingPlaceholder extraction (10 sites)
- atomantic/EscapeMint-Swift#6 — **tests**: strengthened weak/vacuous `testComputeRecommendationNil*` (positive control added), `testComputeCashInterestWithTrade` (accuracy 5.0 → 0.50), `testBackupJSONInvalidFormatHandling` (now calls real actor method)

Build verified: 242 → 243 tests pass on both iOS 17+ and macOS 14+. Zero failures.

### Deferred to next audit
- **[HIGH]** `AuthManager` biometric pref → Keychain (nontrivial cross-platform Keychain helper needed)
- **[CRITICAL]** `EscapeMintApp.swift:312-647` — extract MacContentView (335 lines, defer to dedicated refactor PR)
- **[HIGH]** `FundEngine.swift` — 1347-line god file split (TradeEngine/RecommendationEngine/PortfolioEngine/etc.)
- **[HIGH]** `DashboardView`/`SettingsView` direct `FundStore.shared` access → route through FundDataStore
- **[HIGH]** `ViewCache` split (backtest state vs chart caches) + typed caches to drop `@unchecked Sendable`
- **[HIGH]** `importFromBackupJSON` → Codable BackupDocument (eliminate JSONSerialization)
- **[HIGH]** `FundCharts.computePLPoints` O(n²) → incremental cursor
- **[HIGH]** `BacktestCharts.ChartCardModifier` → reconcile with Theme.CardStyle
- **[HIGH]** `isWideLayout` extension (needs View restructuring to absorb `@Environment` read)
- **[HIGH]** Chart async-loading helper extraction (4× duplicated body in FundCharts)
- **[CRITICAL][MISSING]** New FundStoreTests.swift integration tests for actor I/O paths
- **[CRITICAL][MISSING]** New FundDataStoreTests.swift for stateful in-memory mutations
- **[HIGH][MISSING]** New ViewCacheTests.swift for cache lifecycle
- **[MEDIUM]** Info.plist/project.yml cleanup (GENERATE_INFOPLIST_FILE, UILaunchScreen duplication) — currently deploying successfully so deferred to avoid regression risk
- **[MEDIUM]** Hardcoded font sizes 7-10pt → `@ScaledMetric` for Dynamic Type
- **[MEDIUM]** `withAnimation` in MacContentView/DashboardView collapse not guarded by reduceMotion

### File Ownership Map
| File | Primary Category | Reason |
|------|-----------------|--------|
| EscapeMint/Services/WidgetDataProvider.swift | security | Missing file protection on App Group snapshot (HIGH) |
| EscapeMint/Services/SpotlightIndexer.swift | security | PII leak in contentDescription (MEDIUM) |
| EscapeMint/Services/DCANotificationManager.swift | security | PII leak in notification body (MEDIUM) |
| EscapeMint/Services/AuthManager.swift | security | Biometric pref in UserDefaults (HIGH) |
| EscapeMint/Models/AppStorageKeys.swift | code-quality | Missing keys (MEDIUM) |
| EscapeMint/Theme/AppearanceManager.swift | code-quality | Stringly-typed UserDefaults key (MEDIUM) |
| EscapeMint/Storage/FundStore.swift | architecture | nonisolated(unsafe) race + import silent errors + file protection (HIGH + HIGH + HIGH) |
| EscapeMint/Storage/FundDataStore.swift | architecture | Expose import/export methods (HIGH) |
| EscapeMint/Storage/ViewCache.swift | bugs-perf | @unchecked Sendable Any (MEDIUM) |
| EscapeMint/App/EscapeMintApp.swift | architecture | Extract MacContentView (CRITICAL) |
| EscapeMint/Views/Mac/MacContentView.swift | architecture | NEW — extracted |
| EscapeMint/Views/Dashboard/DashboardView.swift | architecture | Direct FundStore.shared access (HIGH) |
| EscapeMint/Views/Settings/SettingsView.swift | architecture | Direct FundStore.shared access (HIGH) |
| EscapeMint/Views/Backtest/BacktestCharts.swift | dry | ChartCardModifier duplicates CardStyle (HIGH) |
| EscapeMint/Views/FundDetail/FundCharts.swift | dry | Loading placeholder 10x + chart-loading helper 4x (CRITICAL + HIGH) |
| EscapeMint/Views/FundDetail/DerivativesCharts.swift | dry | Loading placeholder duplication |
| EscapeMint/Views/FundDetail/FundDetailView.swift | dry | Loading placeholder usage |
| EscapeMint/Views/IntroGuide/IntroCharts.swift | dry | padding(12).cardStyle() 6x |
| EscapeMint/Theme/PlatformModifiers.swift | dry | isWideLayout extension |
| EscapeMint/Theme/Formatters.swift | bugs-perf | nonisolated(unsafe) currencyFormatterCache (HIGH) |
| EscapeMint/Engine/Converters.swift | bugs-perf | nonisolated(unsafe) holidayCache (HIGH) |
| EscapeMint/Models/FundTypes.swift | bugs-perf | FundEntry.id unstable UUID (MEDIUM) |
| project.yml | platform-swiftui | UILaunchScreen dedup + GENERATE_INFOPLIST_FILE + orientations (HIGH) |
| EscapeMint/App/Info.plist | platform-swiftui | Managed by XcodeGen — clean up duplicates |
| EscapeMint/App/EscapeMint-macOS.entitlements | platform-swiftui | Missing App Groups (HIGH) |
| deploy.sh | platform-swiftui | iOS upload guard + build number order (HIGH) |
| EscapeMint/Views/Shared/LockScreenView.swift | platform-swiftui | .onAppear → .task |
| EscapeMintTests/*Tests.swift | tests | Strengthen existing tests |
| EscapeMintTests/FundStoreTests.swift | tests | NEW — FundStore actor integration tests |
| EscapeMintTests/ViewCacheTests.swift | tests | NEW — ViewCache cache lifecycle tests |

### Security & Secrets
- [ ] **[HIGH]** `WidgetDataProvider.swift:53-58` - Widget snapshot written to App Group container with no `FileProtectionType.completeUntilFirstUserAuthentication`. Fix: apply protection after write (Simple)
- [ ] **[HIGH]** `AuthManager.swift:17-19` - Biometric auth preference stored in `UserDefaults.standard` — bypassable on jailbroken devices. Fix: store in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (Medium)
- [ ] **[MEDIUM]** `SpotlightIndexer.swift:62-64` - Fund portfolio value leaked to Spotlight / Siri suggestions via `contentDescription`. Fix: remove value; keep only ticker/platform (Simple)
- [ ] **[MEDIUM]** `DCANotificationManager.swift:108,112` - Notification body reveals DCA dollar amount on lock screen. Fix: remove amount from body (Simple)

### Code Quality
- [ ] **[MEDIUM]** `DCANotificationManager.swift:40,53,56` - Stringly-typed UserDefaults key not in AppStorageKeys. Fix: add `AppStorageKeys.dcaNotifications` (Simple)
- [ ] **[MEDIUM]** `AppearanceManager.swift:22,26` - Stringly-typed `"appearanceMode"` key. Fix: add to AppStorageKeys (Simple)
- [ ] **[MEDIUM]** `EscapeMintApp.swift:382,386` + `DashboardView.swift:674,678,685` - Sidebar/dashboard collapse keys stringly-typed. Fix: add to AppStorageKeys (Simple)

### DRY & YAGNI
- [ ] **[CRITICAL]** `FundCharts.swift:384,456,527,613` + `DerivativesCharts.swift:385,434,488,656,721` + `FundDetailView.swift:319` - 10 copies of `ProgressView().frame(maxWidth: .infinity).frame(height: Layout.chartFrameHeight)`. Fix: extract as `emChartLoadingPlaceholder` (Simple)
- [ ] **[HIGH]** `BacktestCharts.swift:348-365` - Private `ChartCardModifier` duplicates `Theme.CardStyle`. Fix: use cardStyle() with parameterization (Medium)
- [ ] **[HIGH]** `DashboardView.swift:22-27`, `BacktestCharts.swift:29-35`, `BacktestView.swift:19-25`, `BacktestConfigPanel.swift:11-17` - Identical `isWide` block duplicated 4×. Fix: add `View.isWideLayout` extension to PlatformModifiers.swift (Medium)
- [ ] **[HIGH]** `FundCharts.swift:387-400,459-472,530-543,616-629` - Async chart-loading body repeated 4×. Fix: extract generic helper (Medium)
- [ ] **[MEDIUM]** `IntroCharts.swift:329,402,470,535,616,690` - `.padding(12).cardStyle()` applied 6×. Fix: no new abstraction needed, just verify consistency (Simple)
- [ ] **[MEDIUM]** FundCharts/DerivativesCharts - `isoDateFormatter.date(from: pt.date) ?? Date()` 15×. Fix: use `pt.dateValue` (DateIdentifiable already conformed) (Simple)

### Architecture & SOLID
- [ ] **[CRITICAL]** `EscapeMintApp.swift:312-647` - MacContentView 335 lines embedded in app entry file. Fix: extract to `Views/Mac/MacContentView.swift` (Simple)
- [ ] **[HIGH]** `FundStore.swift:16-17` - `nonisolated(unsafe)` data race on `fundsDirectory`/`isICloud`. Fix: snapshot `fundsDirectory` into local `let` in `loadIfNeeded` before task group; defer `retryICloudIfNeeded` updates to after reads complete (Medium)
- [ ] **[HIGH]** `FundStore.swift:456-459` - `importFromBackupJSON` silently swallows errors with bare `continue`. Fix: log with `Self.logger.warning` before continue (Simple)
- [ ] **[HIGH]** `FundStore.swift` - File protection not applied after `updateConfig`, `importFromBackupJSON` writes. Fix: add `setAttributes([.protectionKey: .complete], ...)` after each write on iOS (Simple)
- [ ] **[HIGH]** `DashboardView.swift:714` + `SettingsView.swift:197,304-419` - Views call `FundStore.shared` directly for import/export/stats. Fix: expose methods on FundDataStore; update callers (Medium)
- [ ] **[HIGH]** `FundStore.swift:350` - `importFromDirectory` uses `try?` silently suppressing directory enumeration errors. Fix: propagate error (Simple)

### Bugs, Performance & Error Handling
- [ ] **[HIGH]** `Formatters.swift:22` - `nonisolated(unsafe) currencyFormatterCache` NumberFormatter not thread-safe, written from multiple threads. Fix: pre-build common formatters at app startup OR guard with lock (Simple)
- [ ] **[HIGH]** `Converters.swift:102` - `nonisolated(unsafe) holidayCache` mutated from background threads. Fix: convert to thread-safe lookup (Simple)
- [ ] **[MEDIUM]** `FundTypes.swift:137` - `FundEntry.id = UUID().uuidString` creates new IDs on every disk reload, causing SwiftUI to tear down all rows. Fix: use deterministic `"\(fundId)-\(date)-\(value)"` (Simple)
- [ ] **[MEDIUM]** `ViewCache.swift:190-192` - `ChartCacheEntry: @unchecked Sendable` wraps `Any`. Fix: use generic `ChartCacheEntry<T: Sendable>` or `any Sendable` (Simple)

### Platform Coverage & SwiftUI Patterns
- [ ] **[HIGH]** `project.yml:44-53` + `Info.plist:29-30` - `UILaunchScreen` defined in BOTH locations (Gotcha #7.3/#7.4). Fix: keep only in `project.yml` info.properties; delete from Info.plist (Simple)
- [ ] **[HIGH]** `deploy.sh:148-158` - iOS `xcrun altool --upload-app` result not error-checked (Gotcha #8). Stashed in-progress work addresses this — integrate. Fix: grep `altool` output for `UPLOAD FAILED` (Simple)
- [ ] **[HIGH]** `EscapeMint-macOS.entitlements` - Missing `com.apple.security.application-groups` (Gotcha #9 related — widget data provider silently fails on macOS). Fix: add App Group entry (Simple)
- [ ] **[HIGH]** `deploy.sh:56-59` - Build number bumped and committed before archive/upload success. Fix: move commit to after successful upload, or trap-revert on failure (Medium)
- [ ] **[MEDIUM]** `project.yml:38,54-57` - iPhone orientations missing UpsideDown + duplicated between INFOPLIST_KEY and info.properties. Fix: consolidate (Simple)
- [ ] **[MEDIUM]** `LockScreenView.swift:39` - `.onAppear { auth.authenticate() }` — prefer `.task` (Simple)

### Test Quality & Coverage
- [ ] **[CRITICAL][MISSING]** `FundStore.swift` — 749 lines, zero tests. Fix: new `FundStoreTests.swift` with temp-directory integration tests (Complex)
- [ ] **[CRITICAL][MISSING]** `FundDataStore.swift` — 405 lines, only `buildAuditEntries` tested. Fix: new in-memory state tests (Complex)
- [ ] **[CRITICAL][MISSING]** `FundStore.importFromBackupJSON` never called by any test; existing test re-implements logic. Fix: direct call against temp file (Medium)
- [ ] **[HIGH][MISSING]** `ViewCache.swift` — zero tests. Fix: new ViewCacheTests.swift for cache hit/miss/invalidation (Medium)
- [ ] **[HIGH][MISSING]** `WidgetDataProvider` tests only cover Codable round-trip, not provider behavior. Fix: add `readSnapshot` nil path test (Simple)
- [ ] **[HIGH][MISSING]** `AdvancedTools.recalculateEntryPrices` untested. Fix: add price computation + zero-shares guard tests (Simple)
- [ ] **[MEDIUM][VACUOUS]** `StorageTests.swift:368-380` `testBackupJSONInvalidFormatHandling` tests Swift stdlib not EscapeMint. Fix: call actual `importFromBackupJSON` (Simple)
- [ ] **[MEDIUM][WEAK]** `EngineTests.swift:954-998` backtest test monotonic prices never exercise sells. Fix: add volatile series + tight numeric assertions (Medium)
- [ ] **[MEDIUM][WEAK]** `EngineTests.swift:219-237` nil recommendation tests use default state only. Fix: non-default FundState values (Simple)
- [ ] **[MEDIUM][WEAK]** `EngineTests.swift:1221` cash interest `accuracy: 5.0` on $360 expected. Fix: tighten to 0.10 (Simple)

---

## Better Swift Audit - 2026-03-26

Summary: 80+ findings across 30+ files from 7 agents. 43 fixed across 8 commits.
Platforms: iOS 17+, macOS 14+ | Build system: XcodeGen

### Fixed — Code Quality & Error Handling
- [x] `FundStore`: `deleteFund`, `deleteAllFunds`, `updateConfig`, `backupFund` — replaced `try?` with proper error propagation
- [x] `FundStore`: migrated all `print()` to `os.Logger` with privacy annotations
- [x] `FundStore`: deduplicated backup DateFormatter to shared static property
- [x] `LivePriceService.PriceData.isStale` — references `cacheTTLSeconds` constant instead of hardcoded 300
- [x] `AddEntryView/DashboardView`: replaced `print()` with `os.Logger`
- [x] Warnings: added missing `.none` case to LABiometryType switches

### Fixed — Architecture
- [x] Moved formatting functions from `Engine/FundEngine.swift` to `Theme/Formatters.swift` (SRP)

### Fixed — Platform & Accessibility
- [x] **CRITICAL**: Wired `AppearanceManager` to `.preferredColorScheme()` (was hard-coded `.dark`)
- [x] Added macOS `Settings` scene (Cmd+, shortcut)
- [x] Added macOS keyboard shortcuts: Cmd+N (New Fund), Cmd+R (Refresh)
- [x] IntroCharts/BacktestTransactions: animations respect `accessibilityReduceMotion`
- [x] macOS interactive rows: added `.accessibilityAddTraits(.isButton)` to DashboardView, ActionableFundsBanner, FundDetailView
- [x] IntroGuideView: progress dots have `.accessibilityLabel("Step N of M")`
- [x] Centralized `@AppStorage` keys to `AppStorageKeys` enum (7 files updated)

### Fixed — Bugs & Performance
- [x] `AuthManager.lock()` now cancels in-progress auth task and resets `isEvaluating`
- [x] `ViewCache.startLoading` stores task handle for cancellation
- [x] `ViewCache` responds to iOS memory pressure by clearing chart/row caches
- [x] `FundSummary.isDueForAction` pre-computed at init (was computed on every access)
- [x] `replaceEntries` re-applies file protection after atomic write (iOS)

### Fixed — DRY
- [x] Extracted `calcPriceAndEquity()` to `EntryFormHelpers.swift` (AddEntryView + EditEntryView)
- [x] Extracted `dcaTipField`/`dcaTipToggle` to shared helpers (EditFundView + CreateFundView)
- [x] Added `Color.backgroundForAction()` to Theme.swift (FundCardView + EscapeMintApp)
- [x] Replaced inline DateFormatters with `todayString()`/`isoDateFormatter`
- [x] IntroCharts: replaced 6x `.padding(12).background(Color.bgCard).cornerRadius(12)` with `.cardStyle()`
- [x] Extracted `computeIsWide()` to PlatformModifiers.swift (4 views)
- [x] Extracted `ToastModifier` — SettingsView + FundDetailView now use `.toast(isPresented:message:)`
- [x] Extracted NSOpenPanel helper — shared between DashboardView + SettingsView
- [x] Consolidated miniStat/statColumn → shared `StatBox` component

### Fixed — Tests
- [x] **CRITICAL**: Added FormulaParserTests.swift (plain numbers, formulas, edge cases)
- [x] Strengthened vacuous assertions in FundMetricsTests (exact values instead of `> 0`)
- [x] Added `testRunBacktestDecliningMarket` scenario
- [x] Added `testRunBacktestHarvestMode` scenario
- [x] Added `testComputeAvailableDateRangeSingleAsset` and empty boundary tests
- [x] Added `testComputeEntryRowsHarvestPartialSell` for harvest-mode sell path

### Remaining — Architecture (deferred to future audit)
- [ ] **[HIGH]** `FundStore.swift:9-10` — `nonisolated(unsafe)` data race on `fundsDirectory`/`isICloud`
- [ ] **[HIGH]** `FundEngine.swift` — god file at 1327 lines (split into focused modules)
- [ ] **[HIGH]** `MacContentView` (334 lines) embedded in EscapeMintApp.swift — extract to separate file
- [ ] **[HIGH]** `FundDataStore` directly references `FundStore.shared` singleton — inject via protocol
- [ ] **[HIGH]** No `#Preview` macros — views can't be previewed without live app environment
- [ ] **[HIGH]** `importFromBackupJSON` uses `JSONSerialization` instead of `Codable` (fragile, stringly-typed)
- [ ] **[MEDIUM]** `ViewCache` stores `Any` with `@unchecked Sendable` — use typed dictionaries
- [ ] **[MEDIUM]** `computePortfolioTimeSeries`/`compute*Points` engine logic in view files — move to Engine

### Remaining — Performance (deferred)
- [ ] **[HIGH]** O(n²) in `computePLPoints`/`computeAPYPoints` — use incremental cursor
- [ ] **[HIGH]** `MacContentView` body recomputes `activeFunds` every render — use `store.summaries`
- [ ] **[MEDIUM]** `FundEntry.id` uses `UUID()` — unstable IDs cause full SwiftUI re-renders on reload

### Remaining — Platform (deferred)
- [ ] **[HIGH]** `.foregroundColor(.white)` not adaptive for light mode (10+ instances)
- [ ] **[MEDIUM]** Hardcoded font sizes (7-10pt) — no Dynamic Type scaling

### Remaining — Security (deferred)
- [ ] **[MEDIUM]** Biometric auth preference in UserDefaults (bypassable on jailbroken devices)
- [ ] **[MEDIUM]** Widget snapshot missing file protection + App Group entitlements

### Remaining — Tests (deferred)
- [ ] **[CRITICAL]** `FundStore` actor methods — 0 integration tests for I/O layer
- [ ] **[HIGH]** `importFromBackupJSON` — test never calls actual actor method

---

## Better Swift Audit - 2026-03-19

Summary: 31 genuine findings across 18 files after deduplication and false-positive filtering.
Platforms: iOS 17+, macOS 14+ | Build system: XcodeGen

### File Ownership Map
| File | Primary Category | Reason |
|------|-----------------|--------|
| .claude/commands/release.md | Security | API key ID exposure |
| EscapeMint/Views/Dashboard/DashboardView.swift | Bugs & Perf | Heavy body computation (highest severity) |
| EscapeMint/Views/Dashboard/PortfolioCharts.swift | DRY | Hardcoded chart heights (8 instances) |
| EscapeMint/Views/FundDetail/FundCharts.swift | DRY | StatBox/MetricCard duplication + axis builders |
| EscapeMint/Views/Backtest/BacktestCharts.swift | DRY | ChartCardModifier duplicates CardStyle |
| EscapeMint/Views/Backtest/BacktestTransactions.swift | Platform | reduceMotion not respected |
| EscapeMint/Views/Backtest/BacktestConfigPanel.swift | Platform | reduceMotion + hardcoded colors |
| EscapeMint/Storage/FundStore.swift | Bugs & Perf | Silent error in directory creation |
| EscapeMint/Storage/ICloudSyncMonitor.swift | Bugs & Perf | Race condition in debounce |
| EscapeMint/Storage/ViewCache.swift | Bugs & Perf | Task not tracked for cancellation |
| EscapeMint/Storage/FundDataStore.swift | Architecture | Singleton coupling (deferred) |
| EscapeMint/Views/FundDetail/FundDetailView.swift | Architecture | Business logic in body (deferred) |
| EscapeMint/Views/FundDetail/AddEntryView.swift | Architecture | Business logic in view (deferred) |
| EscapeMint/Views/FundDetail/DerivativesCharts.swift | DRY | Inline leverage axis definition |
| EscapeMint/Views/IntroGuide/IntroCharts.swift | DRY | Reimplemented axis builders |
| EscapeMintTests/EngineTests.swift | Tests | Weak assertions |

### Security & Secrets
- [ ] **[HIGH]** `.claude/commands/release.md:29` - API key ID exposed in documentation — Fix: replace with placeholder `AuthKey_[YOUR_API_KEY_ID].p8` (Simple)

### Code Quality
- [ ] **[LOW]** `FundStore.swift:41,53,333` - Raw print() instead of Logger (3 instances) (Simple)
- [ ] **[LOW]** `AddEntryView.swift:133,141` - Raw print() for debug logging (Simple)
- [ ] **[LOW]** `DashboardView.swift:686` - Raw print() for error logging (Simple)

### DRY & YAGNI
- [ ] **[HIGH]** `BacktestCharts.swift:348-358` - ChartCardModifier duplicates CardStyle from Theme.swift — Fix: parameterize CardStyle (Simple)
- [ ] **[HIGH]** `PortfolioCharts.swift:330,385,432,487,536,593,654,701` - Hardcoded chart height 150 instead of Layout constant (8 instances) — Fix: use Layout.dashboardChartHeight (Simple)
- [ ] **[HIGH]** `DerivativesCharts.swift:582-594` - Inline leverage axis — Fix: extract emLeverageAxis() (Simple)
- [ ] **[HIGH]** `IntroCharts.swift:249-272` - Reimplemented axis builders — Fix: reuse shared axis functions (Medium)
- [ ] **[MEDIUM]** `FundCharts.swift:113-128` - StatBox duplicates MetricCard — Fix: consolidate (Medium)
- [ ] **[MEDIUM]** `FundCharts.swift:657-703` - Chart axis builders should be in shared file (Medium)
- [ ] **[MEDIUM]** `PortfolioCharts.swift:104-106,444-446` - Color palettes scattered — Fix: move to Theme.swift (Simple)

### Architecture & SOLID
- [ ] **[HIGH]** `ViewCache.swift:1-253` - 23 properties, 5+ concerns — Fix: split into focused managers (Complex, deferred)
- [ ] **[HIGH]** `FundDetailView.swift:142-166` - Business logic in .task block — Fix: extract to ViewModel (Medium, deferred)
- [ ] **[HIGH]** `AddEntryView.swift:129-159` - autoSyncCashFund domain logic in view — Fix: move to Engine (Medium, deferred)
- [ ] **[HIGH]** `FundStore.swift:1-629` - Mixed concerns (I/O + parsing + import/export) — Fix: extract services (Complex, deferred)
- [ ] **[MEDIUM]** `DashboardView.swift:31-44` - Filtering in computed properties every render (Medium, deferred)

### Bugs, Performance & Error Handling
- [ ] **[HIGH]** `DashboardView.swift:31-44` - activeSummaries/closedSummaries recomputed every render — Fix: cache with revision key (Medium)
- [ ] **[HIGH]** `FundStore.swift:312` - Silent error in directory creation during import — Fix: propagate or log error (Simple)
- [ ] **[HIGH]** `ICloudSyncMonitor.swift:79-97` - Race condition: cancelled task can still complete between cancel and guard — Fix: use version counter (Medium)
- [ ] **[MEDIUM]** `ViewCache.swift:14-25` - startLoading() task not stored for cancellation — Fix: store in property (Simple)
- [ ] **[MEDIUM]** `FundStore.swift:343-390` - importFromBackupJSON silently skips failed funds — Fix: log errors (Simple)
- [ ] **[MEDIUM]** `PortfolioCharts.swift:456` - Dictionary grouping computed inside ForEach — Fix: compute once (Simple)

### Platform Coverage & SwiftUI Patterns
- [ ] **[MEDIUM]** `BacktestTransactions.swift:228` - Shimmer animation not respecting reduceMotion — Fix: guard with @Environment (Simple)
- [ ] **[MEDIUM]** `BacktestConfigPanel.swift:multiple` - Slider animations not respecting reduceMotion — Fix: conditional animation (Simple)

### Test Quality & Coverage
- [ ] **[CRITICAL]** FundStore actor — 629 lines, 0 tests — Fix: create FundStoreTests.swift (Complex)
- [ ] **[CRITICAL]** FundDataStore — 298 lines, 0 tests — Fix: create FundDataStoreTests.swift (Complex)
- [ ] **[HIGH]** Import/export error paths — 0 tests — Fix: add error scenario tests (Medium)
- [ ] **[HIGH]** Derivatives engine — computeDerivativesEntryRows/Metrics — 0 tests (Complex)
- [ ] **[HIGH]** ViewCache — 253 lines, 0 tests (Simple)
- [ ] **[MEDIUM][WEAK]** `EngineTests.swift:954-993` - Backtest test only checks synthetic constant data — Fix: add volatility/downturn scenarios (Medium)
- [ ] **[MEDIUM][WEAK]** TSV parsing tests missing edge cases (malformed, extra tabs) (Simple)
- [ ] **[LOW][VACUOUS]** `EngineTests.swift:219-237` - Nil recommendation tests lack meaningful state setup (Simple)

---

## Phase 2: iPhone/iPad Adaptation

**Goal**: Adapt the macOS layouts for smaller screens.

- [ ] Replace sidebar with bottom tab bar on iPhone
- [ ] Stack metric cards vertically (2-column grid on iPhone, 3 on iPad)
- [ ] Collapsible sections for charts
- [ ] Simplified entries list (fewer columns, swipe actions)
- [ ] Sheet-based modals for Create/Edit/Add Entry
- [ ] Pull-to-refresh on dashboard
- [ ] Native date picker in Add Entry

---

## Phase 3: iCloud Sync

- [ ] Configure iCloud Documents entitlement
- [ ] Store fund data in iCloud ubiquity container
- [ ] Automatic sync across devices (macOS ↔ iPhone ↔ iPad)
- [ ] File coordination for conflict resolution
- [ ] No accounts, no server — just iCloud file sync

---

## Phase 4: Polish & Submission

- [ ] App Store screenshots (iPhone 6.5", iPad, Mac)
- [ ] Review contact info (real phone number)
- [ ] App Privacy declaration ("no data collected")
- [ ] First TestFlight build via `./deploy.sh`
- [ ] TestFlight testing
- [ ] Submit for App Store review

---

## Architecture

- **Engine**: Ported from TypeScript to Swift (pure functions, no side effects)
- **Storage**: TSV/JSON files — same format as the web app for data portability
- **UI**: SwiftUI with platform-adaptive layouts (sidebar on macOS, tabs on iPhone)
- **Project**: Managed via `xcodegen` (`project.yml` → `EscapeMint.xcodeproj`)
- **Deployment**: `deploy.sh` for local TestFlight, GitHub secrets configured

## Commands

```bash
xcodegen generate
open EscapeMint.xcodeproj

# Build
xcodebuild build -project EscapeMint.xcodeproj -scheme EscapeMint_iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild build -project EscapeMint.xcodeproj -scheme EscapeMint_macOS \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet

# Deploy
./deploy.sh
./deploy.sh --skip-tests
```

## Key Files

| File | Purpose |
|------|---------|
| `project.yml` | xcodegen project definition (source of truth) |
| `EscapeMint/Models/FundTypes.swift` | All data types + FundSummary |
| `EscapeMint/Models/FundTypeConfig.swift` | Fund type defaults, features, actions |
| `EscapeMint/Engine/FundEngine.swift` | Core computation + recommendation + formatters |
| `EscapeMint/Engine/Converters.swift` | Entry → Trade/CashFlow/Dividend conversion |
| `EscapeMint/Storage/FundStore.swift` | TSV/JSON file I/O (actor-based) |
| `EscapeMint/Storage/FundDataStore.swift` | @MainActor @Observable in-memory state |
| `EscapeMint/Views/Dashboard/DashboardView.swift` | Main dashboard + aggregate metrics |
| `EscapeMint/Views/FundDetail/FundDetailView.swift` | Fund detail + charts + entries |
| `EscapeMint/Engine/BacktestEngine.swift` | Backtest types, presets, simulation |
| `EscapeMint/Views/Backtest/BacktestView.swift` | Backtest UI: config, results |
| `EscapeMint/Theme/Theme.swift` | Adaptive colors, Layout constants, CardStyle |
| `deploy.sh` | Local TestFlight deployment script |

## References

- Web app: `../EscapeMint/` (run `npm run dev`, view at `http://localhost:5551/`)
- Previous native attempt: `../EscapeMint-App-Archive/`
- React Native attempt: `../EscapeMint-App/`

---

## Completed Work (Archive)

<details>
<summary>Phase 1: macOS Desktop App</summary>

All items complete: NavigationSplitView sidebar, dashboard grid with 9 metric cards, fund detail with 4 chart types, entries table, recommendation cards, full engine port (DCA, APY, share tracking, liquidation detection, closed fund metrics), data import from web app directory.
</details>

<details>
<summary>Phase 1.5: Web App Feature Parity</summary>

All items complete: Actionable funds banner with dock badge, pie charts (fund/platform/portfolio allocation), time series charts (APY/Gain over time), audit trail view with filters, platforms management with rename, full backtest view with 13-step intro guide, test data loading.
</details>

<details>
<summary>Better Swift Audit — 2026-03-15 (52 findings)</summary>

Completed: 37 fixed, 8 skipped (acceptable/false positive), 7 deferred (test coverage).
Key fixes: god file refactors (BacktestView 1389→427, FundDetailView 1198→722, DashboardView 751→633), test coverage 3→103 tests, force unwrap elimination, DRY extractions (isoDateFormatter, NumericFieldRow, MetricCard), accessibility improvements.
</details>

<details>
<summary>Better Swift Audit — 2026-03-16 (41 findings)</summary>

Completed: 23 fixed, 6 false positives, 12 deferred (mostly test coverage).
Key fixes: CRITICAL unsafe array access in FundStore, unstable ForEach IDs, path traversal validation, NSFileProtectionComplete, os.Logger adoption, FundDataStore routing (eliminating direct FundStore access), Layout.chartFrameHeight constant (21 instances), semantic colors, accessibility reduceMotion guards, .task migration for animations.
</details>
