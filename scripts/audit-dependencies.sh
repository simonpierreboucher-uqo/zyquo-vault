#!/bin/bash
# Dependency policy audit (CLAUDE.md §11.5): list resolved packages, flag anything
# unexpected, scan for keychain symbols and network libraries in dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Resolved external dependencies =="
if [ -f Package.resolved ]; then
    cat Package.resolved
else
    echo "(none — Package.resolved absent; the only vendored code is CArgon2,"
    echo " the official Argon2 reference implementation, pinned by commit in"
    echo " docs/decisions/ADR-0002-argon2-vendored-reference.md)"
fi

echo
echo "== Vendored CArgon2 license =="
head -5 Sources/CArgon2/LICENSE

FAIL=0
if [ -d .build/checkouts ]; then
    echo
    echo "== Scanning dependency checkouts =="
    if grep -rlE "SecItemAdd|kSecClass|SecKeychain" .build/checkouts 2>/dev/null; then
        echo "FORBIDDEN: dependency touches Keychain APIs"; FAIL=1
    fi
    if grep -rlE "URLSession|NWConnection|CFSocket" --include="*.swift" .build/checkouts 2>/dev/null; then
        echo "WARNING: dependency contains network code — review required"; FAIL=1
    fi
fi

[ "$FAIL" -ne 0 ] && { echo "audit-dependencies: FAILED"; exit 1; }
echo "audit-dependencies: OK"
