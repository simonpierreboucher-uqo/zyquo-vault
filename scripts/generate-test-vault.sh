#!/bin/bash
# (Re)generate the labeled test-vault fixture in Fixtures/ValidVaults/basic-vault
# and validate it with the CLI. Fixture password: example-password-not-real.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PLUGIN_FLAGS=()
if [ -d "$ZYQUO_TESTING_PLUGINS" ]; then
    PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$ZYQUO_TESTING_PLUGINS")
fi

# Build test binaries + runtime symlinks (same workaround as test.sh).
swift build --build-tests "${PLUGIN_FLAGS[@]}" >/dev/null
PF=.build/out/Products/Debug/PackageFrameworks
mkdir -p "$PF"
ln -sfh "$ZYQUO_TESTING_FRAMEWORK" "$PF/Testing.framework"
ln -sf  "$ZYQUO_TESTING_INTEROP"   "$PF/lib_TestingInterop.dylib"
ln -sf  "$ZYQUO_TESTING_INTEROP"   ".build/out/Products/Debug/lib_TestingInterop.dylib"

ZYQUO_GENERATE_FIXTURES="$(pwd)" swift test --skip-build "${PLUGIN_FLAGS[@]}" \
    --filter FixtureGeneration >/dev/null
echo "Fixture written: Fixtures/ValidVaults/basic-vault"

# Validate with the CLI (password over stdin; never as an argument).
swift build --product zyquo-vault-cli "${PLUGIN_FLAGS[@]}" >/dev/null
BIN=$(swift build --show-bin-path "${PLUGIN_FLAGS[@]}")
"$BIN/zyquo-vault-cli" vault info Fixtures/ValidVaults/basic-vault
echo "example-password-not-real" | "$BIN/zyquo-vault-cli" vault verify Fixtures/ValidVaults/basic-vault
