# EscapeMint Review

Reviewed for Apple-platform conventions, correctness, performance, UX fit, and maintainability.

## Findings

### High

1. DCA notifications can remain scheduled after the user disables reminders on a later app launch.
Location: `EscapeMint/Services/DCANotificationManager.swift:78-85`
Why it matters: `cancelAll()` only removes identifiers stored in the in-memory `pendingIdentifiers` array. After a relaunch that array is empty, so disabling reminders can leave previously scheduled `UNNotificationRequest`s behind. That is a user-visible correctness bug and an App Store quality issue.
Recommendation: Remove all app-owned pending requests from `UNUserNotificationCenter` when disabling, or rebuild the identifier list from persisted fund state before cancellation. If these are the only notifications the app owns, `removeAllPendingNotificationRequests()` is the simplest fix.

2. Platform renaming is implemented as add-then-delete, which can duplicate funds and trigger incorrect side effects.
Location: `EscapeMint/Views/Platforms/PlatformsView.swift:238-258`
Why it matters: saving the same normalized platform name appends a duplicate `FundData` in memory because `store.addFund` runs even when `renamedFund.id == fund.id`. On actual renames, each fund incurs an add followed by a delete, which means duplicate recomputes, duplicate notification/widget/index side effects, and transient inconsistent UI state.
Recommendation: Add a dedicated rename mutation in `FundDataStore`/`FundStore` that updates memory once and renames the backing files atomically. Guard early when the normalized name is unchanged.

### Medium

3. `loadEntriesProgressively()` is not actually progressive.
Location: `EscapeMint/Storage/FundDataStore.swift:92-125`
Why it matters: the code waits for every detached read to finish, stores the entire result set in `allEntries`, and only then starts applying batches on the main actor. For large portfolios this increases peak memory, delays first useful results, and defeats the stated "configs first, entries streamed in parallel" design.
Recommendation: stream task-group completions directly into the store, or accumulate small batches as tasks finish and apply them incrementally.

4. Live quote fetching is serialized per ticker and does not validate HTTP responses.
Location: `EscapeMint/Services/LivePriceService.swift:87-132`
Why it matters: stock quotes are fetched one request at a time, duplicate tickers are not deduplicated, and both providers are parsed with `JSONSerialization` without checking `HTTPURLResponse.statusCode`. More funds means slower refreshes and weaker error handling.
Recommendation: deduplicate tickers, batch where the provider allows it, use typed `Codable` responses, and reject non-2xx responses before parsing.

5. Widget snapshot generation performs synchronous file I/O on the main actor after every recompute.
Location: `EscapeMint/Services/WidgetDataProvider.swift:8-18`, `EscapeMint/Services/WidgetDataProvider.swift:53-77`, `EscapeMint/Storage/FundDataStore.swift:362-377`
Why it matters: JSON encoding, file writes, protection-attribute updates, and `WidgetCenter.shared.reloadAllTimelines()` all happen from a `@MainActor` type during the recompute side-effect path. On iPhone/iPad this can create avoidable UI hitches when funds change frequently.
Recommendation: build the snapshot value on the main actor if needed, then encode/write/reload from a background task or a dedicated actor.

6. The backtest date range UI bypasses Apple date controls and locale handling.
Location: `EscapeMint/Views/Backtest/BacktestView.swift:135-156`
Why it matters: raw `TextField` entry for ISO date strings is fragile, non-localized, and less accessible than `DatePicker` or formatter-backed controls. It also accepts invalid dates until later logic fails silently.
Recommendation: store `Date` in UI state, present `DatePicker` controls, and only format to ISO strings at the engine boundary.

7. The generated macOS scheme is not configured for tests, which blocks normal Xcode validation.
Location: `project.yml:20-106`
Why it matters: the repo defines `EscapeMintTests_iOS` and `EscapeMintTests_macOS`, but `xcodebuild test -scheme EscapeMint_macOS -project EscapeMint.xcodeproj` fails because the scheme has no test action configured. That weakens CI and release confidence.
Recommendation: define explicit XcodeGen schemes that attach the platform-specific test bundles to the app schemes, or add a dedicated shared test scheme for each platform.

### Low

8. Several source files are large enough to hurt SwiftUI compile times and code review quality.
Location: `EscapeMint/Engine/FundEngine.swift` (~1359 lines), `EscapeMint/Views/Dashboard/PortfolioCharts.swift` (~974), `EscapeMint/Views/FundDetail/FundDetailView.swift` (~969), `EscapeMint/Storage/FundStore.swift` (~784), `EscapeMint/Views/Dashboard/DashboardView.swift` (~734)
Why it matters: large SwiftUI and engine files increase incremental build cost, make previews and compiler diagnostics worse, and raise the chance of accidental regressions.
Recommendation: split engine math, persistence, and large view sections into smaller focused types/modules before adding more features.

## Validation Notes

- Static review covered app lifecycle, storage, notifications, widget sharing, backtest UI, dashboard/detail views, and project configuration.
- `xcodebuild test -scheme EscapeMint_macOS -project EscapeMint.xcodeproj` failed because the scheme is not configured for the test action.
- `xcodebuild build -scheme EscapeMint_macOS -project EscapeMint.xcodeproj -destination 'platform=macOS' -derivedDataPath /tmp/EscapeMintDerivedData CODE_SIGNING_ALLOWED=NO` started compiling, but the sandbox terminated Swift compilation with `sandbox-exec: sandbox_apply: Operation not permitted`, so this review is primarily source-based rather than fully build-validated.
