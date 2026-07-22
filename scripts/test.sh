#!/bin/bash
# Run the full test suite from the terminal — no Xcode.
# Works around the CLT-only Swift Testing setup (see scripts/env.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PLUGIN_FLAGS=()
if [ -d "$ZYQUO_TESTING_PLUGINS" ]; then
    PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$ZYQUO_TESTING_PLUGINS")
fi

swift build --build-tests "${PLUGIN_FLAGS[@]}"

# Make the Swift Testing runtime discoverable on the test binary's rpaths.
PF=.build/out/Products/Debug/PackageFrameworks
DBG=.build/out/Products/Debug
if [ -d "$ZYQUO_TESTING_FRAMEWORK" ]; then
    mkdir -p "$PF"
    ln -sfh "$ZYQUO_TESTING_FRAMEWORK" "$PF/Testing.framework"
    ln -sf  "$ZYQUO_TESTING_INTEROP"   "$PF/lib_TestingInterop.dylib"
    ln -sf  "$ZYQUO_TESTING_INTEROP"   "$DBG/lib_TestingInterop.dylib"
fi

swift test --skip-build "${PLUGIN_FLAGS[@]}" "$@"
