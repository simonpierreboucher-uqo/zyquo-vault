#!/bin/bash
# SHA-256 checksums for release artifacts in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d dist ] || { echo "error: dist/ missing — run scripts/package-app.sh first" >&2; exit 1; }
OUT="dist/SHA256SUMS"
: > "$OUT"
find dist -maxdepth 1 \( -name "*.dmg" -o -name "*.app" -o -name "zyquo-vault-cli" \) | while read -r artifact; do
    if [ -d "$artifact" ]; then
        # Checksum the app bundle as a deterministic tar stream.
        tar -cf - -C "$(dirname "$artifact")" "$(basename "$artifact")" | shasum -a 256 \
            | sed "s|-|$artifact (tar)|" >> "$OUT"
    else
        shasum -a 256 "$artifact" >> "$OUT"
    fi
done
cat "$OUT"
