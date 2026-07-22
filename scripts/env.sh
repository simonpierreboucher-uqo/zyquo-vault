#!/bin/bash
# Shared build environment for all Zyquo Vault scripts. Source, don't execute.
#
# NO XCODE REQUIRED. Recent macOS SDKs ship SwiftUI's @State/@Bindable and Swift
# Testing's @Test/@Suite as compiler macros whose plugins are Xcode-only. The
# macOS 26.5 SDK under the Command Line Tools declares SwiftUI's as plain property
# wrappers, and the CLT carries the Testing macro plugin in a `testing/` subdir
# SwiftPM does not search. We pin SDKROOT and expose the plugin path; override by
# exporting SDKROOT yourself (with full Xcode selected, any SDK works).

CLT=/Library/Developer/CommandLineTools
LEGACY_SDK="$CLT/SDKs/MacOSX26.5.sdk"
if [ -z "${SDKROOT:-}" ] && [ -d "$LEGACY_SDK" ]; then
    export SDKROOT="$LEGACY_SDK"
fi

export ZYQUO_TESTING_PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"
export ZYQUO_TESTING_FRAMEWORK="$CLT/Library/Developer/Frameworks/Testing.framework"
export ZYQUO_TESTING_INTEROP="$CLT/Library/Developer/usr/lib/lib_TestingInterop.dylib"

zyquo_require() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: required tool '$1' not found" >&2; exit 10; }
}
