#!/bin/bash
# CLAUDE.md §4.2 — absolute Keychain prohibition, plus §4.3 forbidden shortcuts.
# Scans sources AND resolved dependencies. Distinguishes executable code from
# documentation/comments. Exits non-zero on any hit (CI gate).
set -euo pipefail
cd "$(dirname "$0")/.."

FAIL=0

# Keychain storage APIs and wrappers. SecRandomCopyBytes is explicitly ALLOWED.
KEYCHAIN_PATTERNS=(
    "SecItemAdd" "SecItemCopyMatching" "SecItemUpdate" "SecItemDelete"
    "kSecClass" "kSecAttr" "kSecValueData" "SecKeychain"
    "KeychainAccess" "Locksmith" "LAContext.*evaluateAccessControl"
)

# Forbidden engineering shortcuts in crypto/storage paths.
SHORTCUT_PATTERNS=(
    "try!" "fatalError("
)

scan_dir() {
    local dir="$1" label="$2"
    [ -d "$dir" ] || return 0
    for pattern in "${KEYCHAIN_PATTERNS[@]}"; do
        # Strip line comments and doc comments before matching (code vs documentation).
        local hits
        hits=$(grep -rn --include="*.swift" --include="*.m" --include="*.c" --include="*.h" \
            -E "$pattern" "$dir" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:\s*(//|///|\*|/\*)' || true)
        if [ -n "$hits" ]; then
            echo "FORBIDDEN (Keychain, $label): pattern '$pattern'"
            echo "$hits"
            FAIL=1
        fi
    done
}

scan_shortcuts() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    for pattern in "${SHORTCUT_PATTERNS[@]}"; do
        local hits
        hits=$(grep -rnF --include="*.swift" "$pattern" "$dir" 2>/dev/null \
            | grep -vE '^[^:]+:[0-9]+:\s*(//|///|\*)' || true)
        if [ -n "$hits" ]; then
            echo "FORBIDDEN (shortcut in security path): '$pattern'"
            echo "$hits"
            FAIL=1
        fi
    done
}

# Suspicious logging of secret-adjacent values (repo grep required by §11.3).
scan_secret_logging() {
    local hits
    hits=$(grep -rnE --include="*.swift" \
        '(print|NSLog|os_log|Logger\().*(password|secret|totp|apikey|api_key|plaintext|vmk|pkek)' \
        Sources 2>/dev/null | grep -viE 'redacted|never|prohibition|prompt|incorrect|Master password' || true)
    if [ -n "$hits" ]; then
        echo "SUSPICIOUS logging of secret-adjacent values:"
        echo "$hits"
        FAIL=1
    fi
}

scan_dir Sources "sources"
scan_dir Tests "tests"
scan_dir .build/checkouts "resolved dependencies"
scan_shortcuts Sources/ZyquoVaultCrypto
scan_shortcuts Sources/ZyquoVaultStorage
scan_secret_logging

if [ "$FAIL" -ne 0 ]; then
    echo "audit-forbidden-apis: FAILED"
    exit 1
fi
echo "audit-forbidden-apis: OK (no Keychain APIs, no forbidden shortcuts, no secret logging)"
