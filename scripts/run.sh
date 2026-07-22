#!/bin/bash
# Build + package + launch, all from the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/package-app.sh --open
