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
- [ ] Fuzzing harness for header/manifest/import parsers (M8)
- [ ] Memory review of unlock/lock lifecycle with the M3 `VaultSession`
- [ ] Independent cryptographic review before v1.0
