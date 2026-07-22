# Building Zyquo Vault without Xcode

Everything builds, tests, packages, signs, and notarizes from the terminal with only the **Xcode Command Line Tools**. `xcodebuild` and `.xcodeproj` are forbidden by project policy.

## The two CLT-only obstacles, and their fixes (both automated in `scripts/env.sh`)

1. **SwiftUI macros.** The current macOS SDK ships `@State`/`@Bindable` as compiler macros whose plugin (SwiftUIMacros) is Xcode-only. The macOS 26.5 SDK still present under the CLT declares them as plain property wrappers. Fix: `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. With full Xcode selected, any SDK works and the pin is skipped.
2. **Swift Testing macros.** `@Test`/`@Suite` need `libTestingMacros.dylib`, which the CLT ships in `…/swift/host/plugins/testing/` — a directory SwiftPM does not search — and the Testing runtime is not on the test binary's rpath. Fix (automated in `scripts/test.sh`): pass `-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing"` and symlink `Testing.framework` + `lib_TestingInterop.dylib` into `.build/out/Products/Debug/PackageFrameworks/`.

## Commands

```bash
./scripts/bootstrap.sh    # toolchain check + swift package resolve
./scripts/build.sh        # swift build -c release
./scripts/test.sh         # swift test with the plugin/rpath workarounds
./scripts/package-app.sh  # → dist/Zyquo Vault.app, ad-hoc signed
./scripts/run.sh          # package + open
```

## Signing & notarization

- `package-app.sh` uses **ad-hoc** signing (`codesign --sign -`) — sufficient to run locally, requires no certificate.
- `notarize.sh` performs Developer ID distribution: hardened-runtime signing with `Resources/ZyquoVault.entitlements` (App Sandbox, **no network entitlements** — the vault is offline by design), DMG creation, `notarytool submit --wait` with the `MacLustr-Notarize` keychain profile, then stapling of both DMG and app.
- To reproduce on another machine: create the profile once with `xcrun notarytool store-credentials MacLustr-Notarize --apple-id <id> --team-id 3YM54G49SN --password <app-specific-password>`.

## Icon pipeline

`Resources/AppIcon.svg` → PNGs at 16/32/128/256/512 (+@2x) via `cairosvg` → `iconutil -c icns` → `Resources/AppIcon.icns`, copied into the bundle by `package-app.sh`.
