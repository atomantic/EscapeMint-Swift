# EscapeMint Swift

Native SwiftUI port of the EscapeMint web app (`../EscapeMint/`). Portfolio management and DCA tracking for iOS, iPadOS, and macOS.

## Context

This app is a feature-parity port of the web app. The web app is the reference implementation — run `npm run dev` in `../EscapeMint/` and compare at `http://localhost:5551/`.

### What We Port

All computation, visualization, and data management features from the web app:
- Fund engine (DCA recommendations, APY calculations, share tracking, liquidation detection)
- Dashboard with aggregate metrics, pie charts, time series
- Fund detail with 4 chart types, entries table, recommendations
- Backtest with allocation sliders, historical simulation, 13-step intro guide
- Audit trail, platforms management
- Import/export (backup JSON and TSV+JSON directory formats)
- Test data loading

### What We Don't Port

The web app uses Playwright browser automation to import data directly from platforms (Coinbase, Robinhood, etc.). **We do not port this.** Native iOS/macOS cannot run headless browsers.

**Import strategy**: Users who want to import from platforms should use the web app to perform the import, then export a backup JSON from the web app and import that backup into this native app. The Settings view should make this workflow clear.

## Tech Stack

- Swift 6.0, SwiftUI, Swift Charts
- iOS 17.0+ / macOS 14.0+
- XcodeGen (`project.yml` is source of truth, not `.xcodeproj`)
- File-based storage (TSV + JSON) — same format as web app for portability
- Actor-based `FundStore` for thread-safe file I/O
- iCloud Documents for cross-device sync (with local fallback)
- Bundle ID: `net.shadowpuppet.EscapeMint`

## Build Commands

```bash
xcodegen generate
xcodebuild build -project EscapeMint.xcodeproj -scheme EscapeMint_iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild build -project EscapeMint.xcodeproj -scheme EscapeMint_macOS \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet
./deploy.sh          # TestFlight deployment
./deploy.sh --skip-tests
```

## Architecture

- **Engine** (`EscapeMint/Engine/`): Pure functions, no side effects. Ported from TypeScript.
- **Models** (`EscapeMint/Models/`): `FundTypes.swift` (all data types), `FundTypeConfig.swift` (defaults per fund type)
- **Storage** (`EscapeMint/Storage/FundStore.swift`): Actor-based TSV/JSON file I/O
- **Views** (`EscapeMint/Views/`): Platform-adaptive — `NavigationSplitView` on macOS, `TabView` on iOS
- **Theme** (`EscapeMint/Views/Theme.swift`): Adaptive colors for light/dark mode

## Data Format

Funds stored as paired files in `Documents/funds/`:
- `{platform}-{ticker}.json` — fund config (platform, ticker, DCA params, margins, etc.)
- `{platform}-{ticker}.tsv` — entries (22 columns: date, value, cash, action, shares, dividends, margins, etc.)

Backup JSON format: `{ "version": 1, "exported": "...", "funds": [...] }` — single-file export of all funds.

## Key Conventions

- Engine functions are pure — no state mutation, no I/O
- Test/demo funds use platforms prefixed with "test" (coinbasetest, robinhoodtest) and are filtered on import
- Navigation uses `NotificationCenter` posts (selectFund, fundsDidChange, etc.)
- Platform-specific code guarded with `#if os(macOS)` / `#if os(iOS)`
- `FundSummary` pre-computes state + metrics to avoid redundant computation across views

## References

- Web app (reference impl): `../EscapeMint/`
- Archived native attempt: `../EscapeMint-App-Archive/`
- React Native attempt: `../EscapeMint-App/`
- Current plan and progress: `PLAN.md`
