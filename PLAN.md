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
- [ ] Dashboard metric values differ slightly from webapp (~$134K in Total Fund Size) — webapp server uses `calendarDays` for daysActive vs Swift engine's cycle-based daysActive

### Deferred Test Quality Findings

- [ ] Weak assertion patterns in EngineTests (XCTAssertNotNil + force unwrap, try!, re-implemented logic, loose accuracy)
- [ ] Missing test coverage: FundStore actor, FundDataStore, import/export, computeFundSizeForEntry, FundEntry Codable round-trips
- [ ] Missing edge case tests: BacktestEngine (negative prices, zero dividends), FundEngine (margin/derivatives)

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
