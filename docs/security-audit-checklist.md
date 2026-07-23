# Security audit checklist (living document)

Per-milestone gates an auditor (or CI) can verify:

- [x] No Keychain APIs anywhere, including dependencies (`scripts/audit-forbidden-apis.sh`)
- [x] Argon2id vendored from the official reference, pinned, KAT-verified
- [x] HKDF contexts unique and versioned; RFC 5869 vector green
- [x] AES-256-GCM only; fresh random nonces; AAD binding per the byte-level table
- [x] Wrong password ≡ corruption at the unlock boundary; fail closed everywhere
- [x] Header parser rejects malformed/DoS inputs before allocation (test suite)
- [x] Atomic writes with post-write validation; 0600/0700 enforced and tested
- [x] No `try!` / force unwraps / `fatalError` in crypto & storage paths (CI grep)
- [x] No secret-adjacent logging (CI grep); redacted debug output tested
- [x] Fixtures contain only obviously fake secrets
- [x] Fuzzing: deterministic (seeded) mutation + random-buffer passes over the
      header, manifest, record-envelope, attachment, otpauth, base32,
      recovery-key, CSV, Bitwarden-JSON, and export-container parsers — ~2,600
      iterations, zero crashes (`FuzzTests`, `ImportFuzzTests`)
- [x] Backups verified cryptographically before they count; restore never
      overwrites the active vault (tested)
- [x] Performance regression ceilings on unlock / bulk write / decrypt-all /
      deep verify (`PerformanceTests`; numbers in docs/architecture.md)
- [x] Memory review of unlock/lock lifecycle: VMK zeroed via SecureBytes on
      every lock path (manual, auto, sleep, screen lock, quit); decrypted temp
      files destroyed on lock and swept at startup; clipboard cleared on lock;
      residual Swift copy-risk documented in docs/cryptography.md §Memory
- [ ] Independent cryptographic review before v1.0 (external)
