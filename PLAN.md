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
- [x] `NavigationSplitView` with sidebar + detail
- [x] App name/logo at top
- [x] Navigation links: Dashboard (Audit Trail, Platforms — deferred to Phase 2+)
- [x] Active Funds section with fund list (grouped by platform, with DisclosureGroup)
- [x] Closed Funds section (collapsed via DisclosureGroup)
- [x] Settings link at bottom
- [x] Version number
- [x] Recommendation badges per fund in sidebar

### 1B. Dashboard — Full Layout

Match the web app's dashboard grid:
- [x] Header: "Dashboard" title, fund count, Charts toggle, platform filter dropdown, +Add Fund button, Import button
- [x] 9 aggregate metric cards in responsive 5-column grid: Total Fund Size, Current Value, Realized Gain, Realized APY, Unrealized Gain, Liquid Gain, Liquid APY, Projected Annual, Cash Balance
- [x] Grid/Table view toggle (segmented control)
- [x] Table view with full columns (Fund, Platform, Type, Size, Value, Realized, R.APY, Liquid, L.APY, Entries)
- [x] Fund cards grouped by platform with section headers
- [x] Fund cards showing: ticker, portfolio impact %, type badge, category dot, status badge, Size/Value/Realized/Liquid columns, entry count, date range
- [x] Category and Platform breakdown charts (togglable)
- [x] Platform detail pages with P&L summary, breakdown, and funds table

### 1C. Fund Detail — Charts & Data

Match the web app's fund detail page:
- [x] Breadcrumb: Dashboard / Platform / TICKER (macOS only)
- [x] Config summary line: Type, Category, Mode (Accumulate/Harvest), Size, Target APY, Interval, DCA amounts
- [x] BUY/SELL recommendation card with reasoning
- [x] Collapsible Stats section with:
  - [x] Current State grid (Invested, Asset Value, Unrealized, Realized, Realized APY, Liquid P&L, Liquid APY, Cash)
  - [x] Value Chart (line + area) — Swift Charts
  - [x] P&L Chart (Liquid + Realized lines over time) — Swift Charts
  - [x] APY Chart (Liquid + Realized APY lines over time) — Swift Charts
  - [x] Captured Profit Chart (Dividends + Interest cumulative) — Swift Charts
- [x] Full entries table on macOS (Date, Action, Value, Amount, Shares, Dividend, Unrealized, Realized, Fund Size)
- [x] Compact entries list on iOS (last 30 reversed)
- [x] Edit entry buttons per row (pencil icon on macOS, tap on iOS → EditEntryView sheet)
- [x] Delete entry (via EditEntryView with confirmation dialog)
- [x] "+ Take Action" button
- [ ] Audited status badge (deferred — needs config field in UI)

### 1D. Engine Completeness

Port remaining engine features:
- [x] Share tracking for liquidation detection (`trackShares`, `detectFullLiquidation`)
- [x] Closed fund metrics (`computeClosedFundMetrics`)
- [x] Cash fund time-weighted size (`computeCashFundTimeWeightedSize`)
- [x] Full `computeFundMetrics` (`computeFundMetricsForFund`) matching web app
- [x] Full `computeAggregateMetrics` (`computePortfolioMetrics`) with fund shares, dollar-weighted compound APY
- [x] Accumulate vs Harvest mode distinction in `computeStartInput` and `computeExpectedTarget`
- [x] Proper linear APY for per-fund (`computeRealizedAPY`, `computeLiquidAPY`)
- [x] Compound APY for portfolio aggregate (matching web app)
- [x] `computeProjectedAnnualReturn` ported

### 1E. Data Import

- [x] Import from web app's `data/funds/` directory (file picker → copy TSV/JSON files)
- [x] Import available from both Dashboard (macOS) and Settings
- [ ] Shared iCloud Documents folder (deferred to Phase 3)

---

## Phase 1.5: Web App Feature Parity

**Goal**: Close all feature gaps between the macOS app and the web app (`../EscapeMint/`).

### 1.5A. Actionable Funds — Attention Alerts

Match the web app's `ActionableFundsBanner`:
- [x] Engine: `computeActionableFunds()` — find funds overdue/due for DCA based on `interval_days` and last entry date
- [x] `ActionableFundsBanner` on Dashboard — color-coded urgency (red=overdue, amber=due today, yellow=upcoming)
- [x] Dismissible per-session (in-memory set)
- [x] Click alert → navigate to fund detail
- [x] macOS dock badge count for actionable funds (`NSApp.dockTile.badgeLabel`)
- [x] Sidebar badge count on Dashboard nav item

### 1.5B. Dashboard Charts — Pie Charts

Replace text-only category/platform lists with real pie charts:
- [x] Fund Allocation pie chart (Swift Charts `SectorMark`) with legend
- [x] Platform Allocation pie chart with legend
- [x] Portfolio Allocation pie chart (Liquidity/Yield/SOV/Volatility by value)

### 1.5C. Dashboard Charts — Time Series

Match the web app's portfolio-level time series:
- [x] APY Over Time chart (Realized + Liquid APY lines)
- [x] Gain ($) Over Time chart (Realized + Unrealized + Liquid lines)

### 1.5D. Sidebar Navigation — Missing Links

Add web app's nav items to sidebar:
- [x] Backtest nav link
- [x] Audit Trail nav link
- [x] Platforms nav link

### 1.5E. Audit Trail View

Match the web app's audit trail page:
- [x] All entries across all funds in a single table
- [x] Filters: Platform, Action Type, Date Range (From/To), Ticker search
- [x] Aggregate stats cards: total entries, total buys, total sells, net flow, total dividends
- [x] Click ticker → navigate to fund detail
- [x] Pagination (first 500 entries)

### 1.5F. Platforms Management View

Match the web app's platforms page:
- [x] List all platforms with fund counts and total value
- [x] Click platform → navigate to platform detail
- [x] Context menu delete (with guard against platforms with funds)
- [x] Add Fund button (opens CreateFundView — platforms are created implicitly with funds)
- [x] Rename platform (inline editor via context menu, migrates all fund files)

### 1.5G. Backtest View + First-Run Wizard

Match the web app's backtest page and use it as intro:
- [x] First-run detection (`@AppStorage` flag → show backtest intro)
- [x] Asset allocation sliders (SPXL, VTI, BRGNX, TQQQ, BTC, GLD, SLV)
- [x] Investment params: initial cash, weekly DCA, target APY, min profit
- [x] Accumulate vs Harvest mode toggle
- [x] Presets (8 quick-start configs: Blend, TQQQ, SPXL, VTI, BRGNX, BTC, GLD, SLV)
- [x] Historical price data bundled (7 JSON files from web app)
- [x] Backtest engine: blended price normalization, DCA simulation, recommendation engine
- [x] Results: metric cards (final value, invested, gain, APY, max drawdown) + portfolio value chart

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
| `EscapeMint/Engine/BacktestEngine.swift` | Backtest types, presets, historical data loader, simulation |
| `EscapeMint/Views/Backtest/BacktestView.swift` | Backtest UI: intro wizard, config, results chart |
| `EscapeMint/Views/AuditTrail/AuditTrailView.swift` | Audit trail: filterable cross-fund entries table |
| `EscapeMint/Views/Platforms/PlatformsView.swift` | Platforms management: list, navigate, delete |
| `EscapeMint/Views/FundDetail/EditEntryView.swift` | Edit/delete individual entries |
| `EscapeMint/Views/Dashboard/ActionableFundsBanner.swift` | Attention alerts for overdue/due funds |
| `EscapeMint/Views/Dashboard/PortfolioCharts.swift` | Pie charts + time series charts for dashboard |
| `EscapeMint/Resources/*.json` | Historical price data (7 tickers, weekly) |
| `deploy.sh` | Local TestFlight deployment script |

## References

- Web app: `../EscapeMint/` (run `npm run dev`, view at `http://localhost:5551/`)
- Previous native attempt: `../EscapeMint-App-Archive/`
- React Native attempt: `../EscapeMint-App/`
- CI/CD pattern: `../PortOS_Recall/deploy.sh` and `.github/workflows/ci.yml`
