# Zyquo Vault — Threat model (v0, grows with each milestone)

## Assets

1. Master password (never persisted, anywhere, ever).
2. Vault Master Key (VMK) and derived subkeys/DEKs (in memory only while unlocked).
3. Vault contents: secrets, and also *metadata* — titles, usernames, URLs, tags, folder names, item counts are treated as sensitive and live inside ciphertext.
4. The recovery key (M3; user-held, shown once).

## What the design protects against

| Threat | Mitigation | Test coverage |
|---|---|---|
| Theft of the encrypted vault files | Argon2id (≥ 64 MiB, t ≥ 3) + AES-256-GCM; VMK random, wrapped | KAT vectors; wrong-password tests |
| Offline password guessing | Memory-hard KDF, calibrated ~0.75 s/attempt on-device | floor-enforcement tests |
| Modification of header fields | GCM tag on wrapped VMK + AAD binding + HMAC over remaining fields | tamper tests (tag, timestamp bytes) |
| Vault-file substitution/mix-and-match | AAD binds ciphertexts to vault UUID, object UUID, type, version, revision | AAD-mismatch tests |
| Hostile crafted vault files (DoS, crashes) | Strict bounded parser; KDF ceilings checked before allocation | malformed-header suite |
| Partial writes / crashes mid-write | Temp + FULLFSYNC + validate + atomic rename; stale-temp sweep | atomic-writer tests |
| Nonce reuse | Fresh CSPRNG nonce per seal, never derived | nonce-freshness test |
| Secrets in logs/debug output | Redacted types (`SecureBytes`, `SensitiveFieldValue`); CI grep audit | redaction tests |

## Explicit non-goals (documented, not hidden)

- A compromised running session: malware that can read this process's memory while the vault is unlocked gets keys and plaintext.
- A malicious kernel, hypervisor, or hardware (keyloggers, DMA).
- Screen capture / shoulder surfing while a secret is revealed.
- Password entry on an already-compromised machine.
- Physical destruction guarantees for deleted data on SSDs (wear leveling, APFS snapshots): the real control is encryption + key destruction.
- Swift-level perfect memory erasure (see `docs/cryptography.md` §Memory).

## Observable-by-design (accepted metadata leakage)

With the directory format an attacker holding the files can observe: number of record/attachment files, their sizes, and modification times, plus header timestamps and KDF parameters. Names, titles, types, and counts *inside* the manifest are encrypted. Size/padding strategies may be revisited before v1.

## Residual risks under review

- Directory-entry durability after atomic rename (no portable dir-fsync on macOS).
- In-process rate limiting for unlock attempts helps casual attacks only; offline attacks are bounded solely by the KDF.
