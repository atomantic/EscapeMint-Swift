# EscapeMint Swift — Development Plan

Native SwiftUI app for iOS, iPadOS, and macOS. Same bundle ID as the App Store Connect listing (`net.shadowpuppet.EscapeMint`).

## Next Actions

1. **Phase 2: iPhone/iPad Adaptation** — adapt macOS layouts for smaller screens (see below)
2. **Phase 3: iCloud Sync** — cross-device sync via iCloud Documents
3. **Phase 4: Polish & Submission** — screenshots, App Store review
4. **Test coverage** — address deferred test quality findings from audits

## Known Issues

- [ ] iOS 26 liquid glass TabView — using traditional `tabItem` API instead, but appearance still not ideal
- [ ] DRY: identical `calcPriceEquity()` in AddEntryView + EditEntryView (deferred: extract to Engine)
- [ ] Architecture: DashboardView:622 direct FundStore access for import (needs FundDataStore wrapper)
- [x] ~~Dashboard metric values differ from webapp~~ — fixed: derivatives fund metrics, portfolioDays, endDate, fundSize
- [ ] DRY: derivatives entry-processing switch duplicated 3x (FundEngine metrics, FundEngine entry rows, DerivativesCharts) — extract shared accumulator

### Deferred Test Quality Findings

- [ ] Weak assertion patterns in EngineTests (XCTAssertNotNil + force unwrap, try!, re-implemented logic, loose accuracy)
- [ ] Missing test coverage: FundStore actor, FundDataStore, import/export, computeFundSizeForEntry, FundEntry Codable round-trips
- [ ] Missing edge case tests: BacktestEngine (negative prices, zero dividends), FundEngine (margin/derivatives)

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
