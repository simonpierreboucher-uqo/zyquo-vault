#!/bin/bash
# CLAUDE.md §3.2 — no raw visual values inside the UI target. All colors, radii,
# and shadows must come from ZyquoVaultDesign tokens.
set -euo pipefail
cd "$(dirname "$0")/.."

FAIL=0
UI_DIRS=(Sources/ZyquoVaultUI Sources/ZyquoVaultApp)

check() {
    local pattern="$1" message="$2"
    local hits
    hits=$(grep -rnE --include="*.swift" "$pattern" "${UI_DIRS[@]}" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:\s*(//|///)' || true)
    if [ -n "$hits" ]; then
        echo "DESIGN VIOLATION: $message"
        echo "$hits"
        FAIL=1
    fi
}

check 'Color\(red:'                      "raw Color(red:...) — use Zyquo.color tokens"
check 'Color\(\.sRGB'                    "raw sRGB color — use Zyquo.color tokens"
check '#[0-9A-Fa-f]{6}'                  "hardcoded hex color string"
check '\.cornerRadius\([0-9]'            "literal cornerRadius — use Zyquo.radius + continuous style"
check 'RoundedRectangle\(cornerRadius: [0-9]' "literal radius in RoundedRectangle — use Zyquo.radius"
check '\.shadow\(color:.*radius: [0-9]'  "ad-hoc shadow — use zyquoShadow(_:)"
check 'style: \.circular'                "circular corner style — Zyquo uses continuous curvature only"

if [ "$FAIL" -ne 0 ]; then
    echo "audit-design-tokens: FAILED"
    exit 1
fi
echo "audit-design-tokens: OK (UI carries no raw visual values)"
