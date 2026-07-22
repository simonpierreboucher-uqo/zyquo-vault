#!/bin/bash
# Release build from the terminal — no Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

swift build -c release "$@"
echo "Release build complete."
