# ADR-0001 — Terminal-only build via SwiftPM, pinned CLT SDK

**Status:** accepted (2026-07-22)

## Context

CLAUDE.md mandates building, testing, and packaging without Xcode. On this machine (macOS 27, CLT-only), the default SDK's SwiftUI and Swift Testing macros require Xcode-only plugin dylibs.

## Decision

- SwiftPM is the sole project definition; packaging is a shell script assembling the `.app` bundle.
- `SDKROOT` is pinned to the CLT's macOS 26.5 SDK (SwiftUI wrappers are non-macro there); Swift Testing's macro plugin is loaded explicitly from the CLT's `plugins/testing` directory. Both are centralized in `scripts/env.sh` and no-ops when full Xcode is selected.

## Consequences

- Anyone with just the Command Line Tools can build and test.
- We target the 26.5 SDK surface for now; when the project moves to a machine with full Xcode (or Apple restores non-macro declarations), the pin can be dropped without source changes.
