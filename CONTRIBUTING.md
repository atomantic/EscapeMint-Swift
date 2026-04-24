# Contributing

Thanks for your interest in EscapeMint. This is a small, personal-finance-focused project — contributions are welcome, especially around the items on `PLAN.md`.

## Before you start

- Check `PLAN.md` — it lists current known bugs, missing tests, and planned work. Picking from there is the fastest path to a merged PR.
- For a non-trivial change, open an issue first to discuss the approach.

## Setup

```bash
brew install xcodegen xcbeautify
git clone https://github.com/atomantic/EscapeMint-Swift.git
cd EscapeMint-Swift
xcodegen generate
open EscapeMint.xcodeproj
```

If you're signing for a real device, open `EscapeMint.xcodeproj` in Xcode and change the Team under *Signing & Capabilities* to your own Apple Developer team. The team ID in `project.yml` is the upstream maintainer's and is there to make local builds "just work" for them — automatic signing will override it for you.

## Tests

All tests must pass before a PR is mergeable. Run locally:

```bash
xcodebuild test \
  -project EscapeMint.xcodeproj \
  -scheme EscapeMint_macOS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

CI runs both the iOS and macOS test suites on every PR.

## Code style

- Swift 6.0, strict concurrency on. `nonisolated(unsafe)` should be justified in a comment.
- Functional-style preferred over classes where it makes sense. Engine code is pure.
- Follow existing patterns — e.g. new `@AppStorage` keys go in `AppStorageKeys.swift`, not stringly-typed.
- No new third-party dependencies without discussion. The project deliberately owns its code to reduce supply-chain surface.
- Don't commit `.env`, signing keys, App Store Connect credentials, or real user portfolio data.

## Commits & PRs

- Write clear commit messages — "fix: silent data loss on iCloud sync race" beats "fix bug".
- One logical change per PR. Split out refactors from behavior changes.
- Update `PLAN.md` when you close or discover a finding.

## Reporting bugs

Open an issue with:
- Platform (iOS / iPadOS / macOS) and version
- Steps to reproduce (be specific about which fund type / action)
- What you expected vs. what happened
- Logs if you have them (`Console.app` → filter by `net.shadowpuppet.EscapeMint`)

## Security issues

For anything involving potential data leakage, credential handling, or user-data exposure, please email the maintainer directly rather than opening a public issue.
