# Zyquo Vault

A native, local-first, offline password manager and encrypted secret vault for macOS — built with Swift 6, SwiftUI, and CryptoKit, and buildable **entirely from the terminal** (no Xcode).

> **Status: early development (milestones M0–M1 complete).**
> Zyquo Vault is under active development. Until the storage format and cryptographic implementation have undergone an independent security audit, it should not be used as the sole storage location for irreplaceable production credentials.

## What exists today

- **Cryptographic core (M1):** Argon2id key derivation (vendored official reference implementation, validated against the official known-answer vectors), HKDF-SHA256 domain-separated key hierarchy, AES-256-GCM authenticated encryption with canonical associated-data binding, constant-time comparison, `SecureBytes` best-effort secure memory, CSPRNG abstraction over `SecRandomCopyBytes`.
- **Authenticated vault header (M1/M2 subset):** versioned binary format, wrapped Vault Master Key, HMAC header authentication, strict malformed-input rejection, atomic 0600/0700 writes with post-write validation.
- **Design system (M0):** the "Zyquo Soft Light" token set (colors, continuous radii, spacing, type, elevation, motion) with automated WCAG AA contrast tests, plus the signature `ZyquoCard` component.
- **App shell (M0):** a token-styled SwiftUI window that honestly reports milestone progress — the real lock screen and item UI arrive with M3/M4.
- **CLI:** `zyquo-vault-cli vault info|verify <dir>` and `format describe`. The master password is never accepted as a command-line argument.

## Security model in one paragraph

Your master password (plus an optional recovery key, coming in M3) is the only root of trust. Argon2id turns it into a key-encryption key; that unwraps a random 256-bit Vault Master Key; HKDF derives purpose-separated subkeys; everything on disk is AES-256-GCM-encrypted and authenticated, bound to the vault and object identity. **No Apple Keychain is used, ever** — the vault is a self-contained, documented format (`docs/vault-format.md`). No network, no accounts, no telemetry. What that does and does not protect against is spelled out in `docs/threat-model.md`.

## Building — terminal only, no Xcode

Requires macOS 15+ and the Swift 6 toolchain (Xcode Command Line Tools are sufficient; see `docs/build-without-xcode.md` for the SDK-pinning details).

```bash
./scripts/bootstrap.sh        # verify toolchain
./scripts/build.sh            # swift build -c release
./scripts/test.sh             # full test suite (36 tests)
./scripts/package-app.sh      # → dist/Zyquo Vault.app (ad-hoc signed)
./scripts/run.sh              # build + package + open
./scripts/notarize.sh         # Developer ID sign + DMG + notarize + staple
```

Audits (run in CI, all must pass):

```bash
./scripts/audit-forbidden-apis.sh    # Keychain prohibition + forbidden shortcuts
./scripts/audit-design-tokens.sh     # no raw visual values in UI code
./scripts/audit-dependencies.sh      # dependency policy
```

## Storage location

`~/Library/Application Support/Zyquo Vault/vaults/<vault-uuid>/` — one directory per vault: `vault.header`, `vault.manifest` (M2), `records/`, `attachments/`, `journal/`, `backups/`. Directories are 0700, files 0600.

## Honest limitations

- **Forgotten master password = permanent loss**, unless you opt into a recovery key at creation. There are no security questions, no email recovery, no backdoor.
- **Touch ID cannot survive a restart** without the Keychain; Zyquo Vault will only ever offer biometric *re-authorization of an already-unlocked session*.
- Swift cannot guarantee perfect memory erasure; `SecureBytes` is best-effort and documented as such (`docs/cryptography.md`).
- Deleting data on SSDs (wear leveling, APFS snapshots) is not physically guaranteed; encryption plus key destruction is the real control.

## Documentation

`docs/architecture.md` · `docs/threat-model.md` · `docs/cryptography.md` · `docs/vault-format.md` · `docs/design-system.md` · `docs/build-without-xcode.md` · `docs/decisions/` (ADRs) · `SECURITY.md`

## Reporting security issues

See [SECURITY.md](SECURITY.md). Please do not open public issues for suspected vulnerabilities.
