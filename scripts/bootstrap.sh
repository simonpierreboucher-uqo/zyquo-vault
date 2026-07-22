#!/bin/bash
# Verify the toolchain and resolve dependencies. Installs nothing with admin rights.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

echo "== Zyquo Vault bootstrap =="
zyquo_require swift
zyquo_require codesign
zyquo_require hdiutil

SWIFT_VERSION=$(swift --version 2>/dev/null | head -1)
echo "Swift:      $SWIFT_VERSION"
case "$SWIFT_VERSION" in
    *"Swift version 6."*) ;;
    *) echo "error: Swift 6.x required" >&2; exit 11 ;;
esac

OS_VERSION=$(sw_vers -productVersion)
echo "macOS:      $OS_VERSION"
MAJOR=${OS_VERSION%%.*}
if [ "$MAJOR" -lt 15 ]; then
    echo "error: macOS 15 or newer required" >&2; exit 12
fi

echo "SDKROOT:    ${SDKROOT:-<default>}"
[ -d "$ZYQUO_TESTING_PLUGINS" ] && echo "Testing plugins: $ZYQUO_TESTING_PLUGINS" \
    || echo "note: Swift Testing plugin dir missing — tests need full Xcode selected"

swift package resolve
echo "Bootstrap OK."
