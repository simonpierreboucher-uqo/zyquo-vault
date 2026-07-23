#!/bin/bash
# Release build → dist/Zyquo Vault.app, ad-hoc signed, verified, ready to open.
# No Xcode, no paid certificate required. For Developer ID signing + notarization
# use scripts/notarize.sh (documented in docs/build-without-xcode.md).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

APP_NAME="Zyquo Vault"
BUNDLE_ID="dev.zyquo.vault"
VERSION="0.9.0"
EXECUTABLE="ZyquoVaultApp"
DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"

echo "== Building release =="
swift build -c release

echo "== Assembling bundle =="
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

BIN=$(swift build -c release --show-bin-path)
cp "$BIN/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

# CLI ships next to the app for terminal users.
cp "$BIN/zyquo-vault-cli" "$DIST/zyquo-vault-cli"

# App icon (vault variant of the Zyquo mark — orange Z + padlock).
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Simon-Pierre Boucher. All rights reserved.</string>
</dict>
</plist>
PLIST

chmod -R u+rwX,go+rX "$APP_DIR"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE"

echo "== Ad-hoc signing =="
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Packaged: $APP_DIR"

if [ "${1:-}" = "--open" ]; then
    open "$APP_DIR"
fi
