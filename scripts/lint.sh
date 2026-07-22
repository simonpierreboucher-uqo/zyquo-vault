#!/bin/bash
# Format/lint gate. Uses swift-format when available (bundled with recent
# toolchains as `swift format`); falls back to a basic hygiene check otherwise.
# CI mode: lint.sh ci  → fails on violations instead of fixing.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-fix}"

if swift format --version >/dev/null 2>&1; then
    if [ "$MODE" = "ci" ]; then
        swift format lint --recursive Sources Tests Package.swift
    else
        swift format --in-place --recursive Sources Tests Package.swift
    fi
    echo "lint: OK (swift format, mode=$MODE)"
    exit 0
fi

echo "note: swift-format unavailable; running basic hygiene checks"
FAIL=0
if grep -rn --include="*.swift" $'\t' Sources Tests >/dev/null 2>&1; then
    echo "lint: tabs found (use 4 spaces)"; FAIL=1
fi
if grep -rnE --include="*.swift" ' +$' Sources Tests >/dev/null 2>&1; then
    echo "lint: trailing whitespace found"; FAIL=1
fi
[ "$FAIL" -ne 0 ] && [ "$MODE" = "ci" ] && exit 1
echo "lint: OK (basic checks)"
