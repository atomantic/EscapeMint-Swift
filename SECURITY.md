# Security Policy

EscapeMint takes a deliberately small attack surface seriously. This document explains
what data the app handles, how to report a vulnerability, and what to expect in return.

## Supported versions

EscapeMint is shipped as a single, continuously updated app. Security fixes target the
latest released version on the App Store and the current `main` branch. Older builds are
not patched in place — update to the latest version to receive fixes.

| Version                  | Supported |
| ------------------------ | --------- |
| Latest App Store release | ✅        |
| `main` (development)     | ✅        |
| Older releases           | ❌        |

## Scope and threat model

EscapeMint is intentionally designed to minimize what could go wrong:

- **No accounts, no server.** There is no external authentication, no login, and no
  backend the app talks to. Your data never leaves your control by design.
- **Data stays on-device or in your own iCloud.** All fund, entry, and App-Group data
  is stored locally or in your personal iCloud Documents container. There is no shared
  storage and nothing is transmitted to the maintainer.
- **Biometric lock is local-only.** Face ID / Touch ID gating is enforced on-device and
  backed by the system Keychain. It controls access to the app on your device only and
  is not an authentication mechanism for any remote service.
- **No analytics, no ads, no third-party SDKs.** The project deliberately owns its code
  to reduce supply-chain exposure (see `CONTRIBUTING.md`).

Reports most relevant to this threat model include, for example:

- Ways user portfolio data could be leaked off-device or exposed to other apps.
- Bypasses of the biometric lock or Keychain handling.
- Insecure handling of imported/exported backup files or App-Group data.
- Supply-chain or build-pipeline weaknesses.

Out of scope: issues that require physical access to an already-unlocked device, or
findings against the separate [EscapeMint web app](https://github.com/atomantic/EscapeMint),
which has its own repository.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.** Disclosing a
vulnerability publicly before it is fixed puts users at risk.

Instead, report it privately through either of these channels:

1. **GitHub private vulnerability reporting** (preferred) — use the
   **Security → Report a vulnerability** tab on the
   [EscapeMint-Swift repository](https://github.com/atomantic/EscapeMint-Swift/security/advisories/new).
2. **Direct contact with the maintainer** — as noted in `CONTRIBUTING.md`, email the
   maintainer directly for anything involving potential data leakage, credential
   handling, or user-data exposure. You can reach the maintainer via the contact
   listed on the [GitHub profile](https://github.com/atomantic).

When reporting, please include:

- The platform (iOS / iPadOS / macOS) and app version.
- A clear description of the issue and its potential impact.
- Steps to reproduce, or a proof of concept if you have one.
- Any logs or screenshots that help (`Console.app` → filter by `net.shadowpuppet.EscapeMint`).

## What to expect

- **Acknowledgement** within 5 business days of your report.
- **An initial assessment** (severity, scope, and whether we can reproduce it) within
  10 business days.
- **Status updates** as we work toward a fix, and notification when a fix ships.
- **Credit** for the disclosure if you would like it — let us know how you'd like to be
  acknowledged.

Please give us a reasonable window to ship a fix before any public disclosure. As a
free, single-maintainer project, timelines are best-effort, but we will keep you
informed throughout.

Thank you for helping keep EscapeMint and its users safe.
