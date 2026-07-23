# Zyquo Vault — Architecture

## Module map (SwiftPM targets, one-way dependencies)

```
ZyquoVaultApp ──▶ ZyquoVaultUI ──▶ ZyquoVaultDesign
                        │
                        ├──▶ ZyquoVaultDomain
                        └──▶ ZyquoVaultStorage ──▶ ZyquoVaultCrypto ──▶ CArgon2 (vendored C)
                                       │
zyquo-vault-cli ───────────────────────┘          ZyquoVaultImport ──▶ ZyquoVaultDomain
```

- **ZyquoVaultCrypto** depends on nothing internal except the vendored Argon2 C target. It owns: `SecureBytes`, `SecureRandomSource`, `Argon2id`, `KeyDerivation` (HKDF contexts), `AEADEngine` + `AssociatedData`, `KeyHierarchy`, `constantTimeEquals`, `CryptoError`.
- **ZyquoVaultStorage** owns the on-disk format: `VaultHeader` (binary codec + strict parser), `AtomicFileWriter`, `VaultStore` (create/open), `StorageError`. M2 adds manifest, records, journal, locking.
- **ZyquoVaultDomain** is pure value types (`VaultItem`, `VaultField`, `SensitiveFieldValue`) — `Codable` strictly inside the encrypt/decrypt boundary.
- **ZyquoVaultDesign** is the §3 token system + component library; the UI target is forbidden (and CI-audited) from carrying raw visual values.
- **ZyquoVaultUI** holds views only — no crypto, no storage calls beyond the session facade (M3 adds the `VaultSession` actor as the single owner of key material).

## Concurrency model

Swift 6 language mode, strict concurrency. Mutable shared state lives in actors (M3+: `VaultSession`, `VaultRepository`, `ClipboardService`, …). KDF/crypto/IO never run on the main actor. `SecureBytes` is a reference type with internal locking (`@unchecked Sendable`, documented invariants).

## Error philosophy

Typed error enums per layer (`CryptoError`, `StorageError`). Wrong-password and corruption are indistinguishable at the unlock boundary by design; internal diagnostics stay local and sanitized. No `try!`, force unwraps, or `fatalError` in crypto/storage paths (CI-audited).

## Performance profile (M8, MacBook Pro / Apple Silicon, floor KDF params)

Measured by `PerformanceTests` (generous regression ceilings asserted in CI):

- Unlock (Argon2id 64 MiB / t=3 + header + manifest + journal scan): **0.14 s** — production vaults calibrate to ~0.75 s by design (§5.3).
- Write 200 records (each journalled, two `F_FULLFSYNC` atomic writes): **3.0 s** (~15 ms/record).
- Decrypt-all summary/search-index build over 200 records: **0.013 s**.
- Deep integrity verification of 200 records: **0.007 s**.

## Build system

SwiftPM only; no `.xcodeproj`, no `xcodebuild`. See `docs/build-without-xcode.md` for the SDK pinning and Swift Testing plugin workarounds that make Command Line Tools sufficient.
