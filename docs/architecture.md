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

## Build system

SwiftPM only; no `.xcodeproj`, no `xcodebuild`. See `docs/build-without-xcode.md` for the SDK pinning and Swift Testing plugin workarounds that make Command Line Tools sufficient.
