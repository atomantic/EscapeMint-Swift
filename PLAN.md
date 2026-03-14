# EscapeMint Swift — Development Plan

Native SwiftUI app for iOS, iPadOS, and macOS. Same bundle ID as the App Store Connect listing (`net.shadowpuppet.EscapeMint`).

## Architecture

- **Engine**: Ported from TypeScript to Swift (pure functions, no side effects)
- **Storage**: TSV/JSON files — same format as the web app for data portability
- **UI**: SwiftUI with platform-adaptive layouts (sidebar on macOS, tabs on iPhone)
- **Project**: Managed via `xcodegen` (`project.yml` → `EscapeMint.xcodeproj`)
- **Deployment**: `deploy.sh` for local TestFlight, GitHub secrets configured

## Current Status

### Done
- [x] Engine ported: fund state, DCA recommendations, APY calculations, time-weighted fund size
- [x] Storage layer: read/write TSV+JSON, same format as web app
- [x] FundSummary extracted to avoid redundant computation
- [x] Basic screens: Dashboard, FundDetail, CreateFund, AddEntry, EditFund, Settings
- [x] Swift Charts value chart on fund detail
- [x] App icon from Logo.png (all sizes: iPhone, iPad, Mac)
- [x] Bundle ID registered (`net.shadowpuppet.EscapeMint`)
- [x] App Store Connect listing created with metadata
- [x] GitHub secrets configured (all 4)
- [x] Builds verified for both iOS and macOS
- [x] Code quality review: 8 issues fixed

### Known Issues
- [x] Missing Bundle ID on simulator install — fixed (Info.plist needed explicit CFBundleIdentifier)
- [ ] iOS 26 liquid glass TabView — using traditional `tabItem` API instead, but appearance still not ideal
- [ ] UI is functional but not polished — doesn't match the web app's design quality

---

## Phase 1: macOS Desktop App (Next Session)

**Goal**: Pixel-perfect match of the web app's desktop experience using SwiftUI on macOS.

Use `http://localhost:5551/` as the visual reference (run `npm run dev` in the web repo). Compare side-by-side using Playwright MCP or browser screenshots.

### 1A. Navigation — Sidebar

Match the web app's left sidebar:
- [ ] `NavigationSplitView` with sidebar + detail
- [ ] App name/logo at top
- [ ] Navigation links: Dashboard, Audit Trail, Platforms
- [ ] Active Funds section with fund list (grouped by platform)
- [ ] Closed Funds section (collapsed)
- [ ] Settings link at bottom
- [ ] Version number

### 1B. Dashboard — Full Layout

Match the web app's dashboard grid:
- [ ] Header: "Dashboard" title, fund count ("12 active • 10 closed"), Charts toggle, platform filter dropdown, +Add Fund button, Import button
- [ ] 9 aggregate metric cards in a responsive grid (not horizontal scroll): Total Fund Size, Current Value, Realized Gain, Realized APY, Unrealized Gain, Liquid Gain, Liquid APY, Projected Annual, Cash Balance
- [ ] Grid/Table view toggle
- [ ] Fund cards grouped by platform with section headers linking to platform detail
- [ ] Fund cards showing: ticker, platform, portfolio impact %, type badge, category badge, status badge, Size/Value/Realized/Liquid columns, entry count, date range

### 1C. Fund Detail — Charts & Data

Match the web app's fund detail page:
- [ ] Breadcrumb: Dashboard / Platform / TICKER
- [ ] Header badges: Audited status, BUY/SELL recommendation, Cash balance link
- [ ] Config summary line: Type, Mode (Accumulate/Harvest), Size, Target APY, Interval, DCA amounts, Max@, Profit threshold
- [ ] Collapsible Stats section with:
  - [ ] Current State card (Invested, Asset Value, Unrealized, Realized, Realized APY, Liquid P&L, Liquid APY)
  - [ ] P&L Chart (Liquid + Realized lines over time) — Swift Charts
  - [ ] APY Chart (Liquid + Realized APY lines over time) — Swift Charts
  - [ ] Value & Allocation Chart (Value, Invested, Target area chart) — Swift Charts
  - [ ] Captured Profit Chart (Dividends + Extracted area chart) — Swift Charts
- [ ] Entries table with columns: Date, Equity, Action, Amount, Dividend, Extracted, Unrealized, Realized, Liquid P&L, Realized APY, Liq APY, Fund Size
- [ ] Edit entry buttons per row
- [ ] "+ Take Action" button

### 1D. Engine Completeness

Port remaining engine features:
- [ ] Share tracking for liquidation detection (`trackShares`, `detectFullLiquidation`)
- [ ] Closed fund metrics (`computeClosedFundMetrics`)
- [ ] Cash fund time-weighted size (`computeCashFundTimeWeightedSize`)
- [ ] Full `computeFundMetrics` and `computeAggregateMetrics` from aggregate.ts
- [ ] Accumulate vs Harvest mode distinction in recommendations

### 1E. Data Import

- [ ] Import from web app's `data/funds/` directory (file picker → copy TSV/JSON files)
- [ ] Or: shared iCloud Documents folder between web and native

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

## Commands

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Open in Xcode
open EscapeMint.xcodeproj

# Build for iOS simulator
xcodebuild build -project EscapeMint.xcodeproj -scheme EscapeMint_iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet

# Build for macOS
xcodebuild build -project EscapeMint.xcodeproj -scheme EscapeMint_macOS \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet

# Deploy to TestFlight
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
| `EscapeMint/Views/Dashboard/DashboardView.swift` | Main dashboard + FundCardView + aggregate |
| `EscapeMint/Views/FundDetail/FundDetailView.swift` | Fund detail + charts + entries |
| `deploy.sh` | Local TestFlight deployment script |

## References

- Web app: `../EscapeMint/` (run `npm run dev`, view at `http://localhost:5551/`)
- Previous native attempt: `../EscapeMint-App-Archive/`
- React Native attempt: `../EscapeMint-App/`
- CI/CD pattern: `../PortOS_Recall/deploy.sh` and `.github/workflows/ci.yml`
