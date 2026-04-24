# EscapeMint

Native SwiftUI portfolio tracker for iOS, iPadOS, and macOS. Manual-entry DCA tracking with recommendations, backtesting, and historical charts — no accounts, no server, your data stays in iCloud Documents (or on-device only).

This is the native Swift port of the [EscapeMint web app](https://github.com/atomantic/EscapeMint). Same data format, same engine math, re-implemented in Swift so the app runs offline and ships to the App Store.

## Requirements

- macOS with Xcode 16.0+
- Swift 6.0 (bundled with Xcode 16)
- iOS 17.0+ / macOS 14.0+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick Start

```bash
# Clone
git clone https://github.com/atomantic/EscapeMint-Swift.git
cd EscapeMint-Swift

# Generate the Xcode project from project.yml
xcodegen generate

# Open in Xcode
open EscapeMint.xcodeproj
```

From Xcode: pick **EscapeMint_iOS** or **EscapeMint_macOS** in the scheme picker and hit ▶.

## Build & Test from the command line

```bash
# Build (iOS simulator, no signing)
xcodebuild build \
  -project EscapeMint.xcodeproj \
  -scheme EscapeMint_iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

# Build (macOS)
xcodebuild build \
  -project EscapeMint.xcodeproj \
  -scheme EscapeMint_macOS \
  -destination 'platform=macOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

# Run tests (macOS — fastest)
xcodebuild test \
  -project EscapeMint.xcodeproj \
  -scheme EscapeMint_macOS \
  -destination 'platform=macOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

CI runs iOS + macOS tests on every PR — see `.github/workflows/ci.yml`.

## Project layout

```
EscapeMint/
  App/            App entry, Info.plist, entitlements, assets
  Engine/         Pure-function math (FundEngine, BacktestEngine, Converters)
  Models/         FundTypes, FundTypeConfig, AppStorageKeys
  Storage/        FundStore (actor I/O), FundDataStore (MainActor state), iCloud sync
  Services/       Notifications, widget snapshot, auth, Spotlight indexer
  Theme/          Colors, formatters, platform modifiers
  Views/          All SwiftUI — Dashboard, FundDetail, Backtest, Settings, etc.
EscapeMintTests/  XCTest suite (run on both iOS and macOS)
EscapeMintWidget/ WidgetKit extension (iOS only)
```

`project.yml` is the source of truth — `EscapeMint.xcodeproj` is regenerated from it by XcodeGen.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the short version.

## License

[MIT](LICENSE).
