#!/bin/bash
# Developer ID distribution pipeline: sign (hardened runtime + sandbox
# entitlements) → DMG → notarize → staple. Requires the packaged app from
# scripts/package-app.sh and a configured notarytool keychain profile.
#
# Identity and notarization flow reused from the Zyquo macOS app (zyquo-macos).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Zyquo Vault"
APP_DIR="dist/$APP_NAME.app"
DMG_NAME="dist/ZyquoVault.dmg"
IDENTITY="Developer ID Application: Simon-Pierre Boucher (3YM54G49SN)"
KEYCHAIN_PROFILE="MacLustr-Notarize"
ENTITLEMENTS="Resources/ZyquoVault.entitlements"

[ -d "$APP_DIR" ] || { echo "error: $APP_DIR missing — run scripts/package-app.sh first" >&2; exit 1; }

echo "== Signing (Developer ID, hardened runtime, App Sandbox) =="
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "Signature valid."

echo "== Creating DMG =="
rm -f "$DMG_NAME"
DMG_TEMP="dist/dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP_DIR" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DMG_NAME"
rm -rf "$DMG_TEMP"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_NAME"
echo "DMG created: $DMG_NAME"

echo "== Notarizing =="
xcrun notarytool submit "$DMG_NAME" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG_NAME"
xcrun stapler staple "$APP_DIR"
echo "Notarization complete — $DMG_NAME is ready for distribution."
