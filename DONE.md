# Done Log

Archived from PLAN.md. For release notes see git tags and `.changelogs/` (if present).

## 2026-04 — Pre-Open-Source Push (repo flipped public)

- CI workflow re-enabled and wired to `EscapeMint_iOS` / `EscapeMint_macOS` schemes
- README rewritten with App Store link, screenshots, free-forever pitch
- CONTRIBUTING.md created (setup, test command, code style, PR format, security reporting)
- CLAUDE.md banner pointing humans to README + CONTRIBUTING
- PLAN.md trimmed: historical audits collapsed, then archived here
- Disk-write failure surfacing across `FundDataStore` mutation paths via `recordDiskError` → root-view toast
- `FundStore.importFromBackupJSON` atomic config+TSV writes with rollback on partial failure
- `ICloudSyncMonitor.scheduleReload` coalescing flag (`isReloadInFlight`)
- `FundDataStore.renameFund` extracted to pure `applyRenames(to:edits:)` + 3 unit tests
- `DCANotificationManager.cancelAll` idempotency test
- DCA permission denial surfaces via observable `isEnabled` + Settings toast
- Converters TSV round-trip test for emoji, accented chars, RTL, combining marks
- iOS Entries table horizontally scrollable with full column set
- TestFlight deploy workflow triggered on `v*.*.*` tags

## 2026-04-07 — Better Swift Audit (PRs #3–#6 merged, 242 → 243 tests)

- **Security** (#3): WidgetDataProvider file protection, SpotlightIndexer/DCANotificationManager PII removal, `AppStorageKeys` centralization
- **Platform** (#4): deploy.sh altool error guard + build-number rollback trap, macOS App Group entitlement, LockScreenView `.task`
- **Architecture / Perf / DRY** (#5): FundStore directory-state `OSAllocatedUnfairLock`, Formatters/Converters thread-safe caches, stable `FundEntry.id`, FundStore error propagation + file protection, `EMChartLoadingPlaceholder` extraction across 10 sites
- **Tests** (#6): strengthened `testComputeRecommendationNil*` (positive control), `testComputeCashInterestWithTrade` (5.0 → 0.50), `testBackupJSONInvalidFormatHandling` (now calls real actor method)

## 2026-03-26 — Better Swift Audit (43 fixes across 8 commits)

- Code Quality: FundStore error propagation, `os.Logger` migration, deduplicated DateFormatter, switch case completeness
- Architecture: moved formatting from Engine to `Theme/Formatters.swift`
- Platform: `AppearanceManager` wired to `.preferredColorScheme`, macOS `Settings` scene + Cmd+, / Cmd+N / Cmd+R shortcuts, reduceMotion guards, accessibility traits
- Bugs/Perf: `AuthManager.lock` cancels in-flight, ViewCache task cancellation + memory pressure response, `FundSummary.isDueForAction` pre-computed, `replaceEntries` re-applies file protection
- DRY: `calcPriceAndEquity`, `dcaTipField`, `Color.backgroundForAction`, `ToastModifier`, `NSOpenPanel` helper, `StatBox` consolidation
- Tests: `FormulaParserTests`, decline/harvest backtest scenarios, vacuous-assertion strengthening

## 2026-03-19 — Better Swift Audit (partial)

- Zero `print()` calls remaining in services/views (all on `os.Logger`)
- `AddEntryView.autoSyncCashFund` refactored to pure helper + batched writes through `FundDataStore.appendEntries` (single recompute)
- `DashboardView` active/closed summaries + platform groupings cached in `@State`
- Per-fund metrics cache: mutations only recompute touched funds (3× → 1× startup recompute)

## 2026-03-16 — Better Swift Audit (23 fixed)

- CRITICAL unsafe array access in FundStore
- Unstable ForEach IDs hardened
- Path traversal validation
- NSFileProtectionComplete adoption
- FundDataStore routing (eliminated direct FundStore access)
- `Layout.chartFrameHeight` constant (21 instances)
- Semantic colors, `.task` migration for animations

## 2026-03-15 — Better Swift Audit (37 fixed)

- God file refactors: BacktestView 1389→427, FundDetailView 1198→722, DashboardView 751→633
- Test coverage 3 → 103 tests
- Force unwrap elimination
- DRY extractions: `isoDateFormatter`, `NumericFieldRow`, `MetricCard`
- Accessibility improvements

## Phase 1 — macOS Desktop App

NavigationSplitView sidebar, dashboard with 9 metric cards, fund detail with 4 chart types, entries table, recommendation cards, full engine port (DCA/APY/share tracking/liquidation detection/closed fund metrics), web app directory import.

## Phase 1.5 — Web App Feature Parity

Actionable funds banner with dock badge, pie charts (fund/platform/portfolio allocation), time series charts (APY/Gain over time), audit trail with filters, platforms management with rename, full backtest with 13-step intro guide, test data loading.

## Phase 2 — iPhone/iPad Adaptation

Bottom tab bar on iPhone, sidebar on macOS, vertical metric stacks on iPhone (grid on iPad/Mac), sheet-based modals for Create/Edit/Add Entry, pull-to-refresh on dashboard, native date picker, guided Add-Entry wizard with per-fund equity-input mode + editable Review & Save page, iOS Entries table horizontally scrollable.

## Phase 3 — iCloud Sync

iCloud Documents entitlement configured, cross-device sync (macOS ↔ iPhone ↔ iPad), file coordination + conflict handling, fresh-install + post-sleep iCloud reconnection fixes, hardened import paths.

## Phase 4 — Polish & App Store Submission

App Store screenshots (iPhone, iPad, Mac), App Privacy declaration ("no data collected"), TestFlight via `deploy.sh`, App Store review approval, **app live on App Store** (see README link).
