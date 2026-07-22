# Zyquo Vault — On-disk format (v1, in progress)

Goal: an independent implementation can read a vault from this document alone. Sections marked **(M2+)** are not yet implemented; everything else is authoritative for the current code.

## Layout

```
~/Library/Application Support/Zyquo Vault/
  vaults/<vault-uuid>/
    vault.header        # this document, §Header
    vault.manifest      # (M2) encrypted inventory
    records/<uuid>.zyqrec     # (M2)
    attachments/<uuid>.zyqatt # (M6)
    journal/            # (M2) transaction journal — no plaintext secrets
    backups/            # (M6)
    lock                # (M2) process lock metadata
```

Directories 0700, files 0600, validated at startup. Permissions are hygiene, never a substitute for encryption.

## Header (`vault.header`)

Canonical binary; all integers **big-endian**; maximum size 4096 bytes; no JSON.

| Offset | Size | Field | Constraints |
|---|---|---|---|
| 0 | 4 | magic `"ZYQV"` (5A 59 51 56) | exact |
| 4 | 4 | format version | currently 1 |
| 8 | 4 | minimum reader version | ≥ 1, ≤ format version, ≤ reader's supported version |
| 12 | 16 | vault UUID | RFC 4122 byte order |
| 28 | 8 | createdAt (unix seconds) | |
| 36 | 8 | updatedAt (unix seconds) | |
| 44 | 4 | KDF id | 1 = Argon2id v19; anything else rejected |
| 48 | 1 | salt length S | 16 ≤ S ≤ 64 |
| 49 | S | Argon2id salt | |
| 49+S | 4 | Argon2id memory (KiB) | 65536 ≤ m ≤ 4194304 |
| 53+S | 4 | Argon2id iterations | 3 ≤ t ≤ 64 |
| 57+S | 4 | Argon2id parallelism | 1 ≤ p ≤ 8; m ≥ 8p |
| 61+S | 1 | Argon2id output length | 32 ≤ L ≤ 64 |
| 62+S | 4 | key-wrap algorithm | 1 = AES-256-GCM |
| 66+S | 12 | wrap nonce | |
| 78+S | 4 | wrapped-VMK ciphertext length C | must be 32 |
| 82+S | C | wrapped-VMK ciphertext | |
| 82+S+C | 16 | wrap GCM tag | |
| 98+S+C | 4 | feature flags | must be 0 in v1; unknown bits ⇒ reject |
| 102+S+C | 1 | header-auth version | 1 = HMAC-SHA256 |
| 103+S+C | 32 | header-auth tag | HMAC-SHA256 over the header body: bytes 0 up to (not including) the auth-version byte at offset 102+S+C |
| 135+S+C | — | end | trailing bytes ⇒ reject |

With the default S = 16, C = 32 the header is 183 bytes.

Wrapped-VMK AAD: the canonical 57-byte AAD structure (see `docs/cryptography.md`) with vault UUID, object UUID = vault UUID, object type 1, schema version = format version, revision 0, algorithm 1.

Header-auth key: HKDF-SHA256(VMK, salt = vault-UUID bytes, info = `zyquo-vault/v1/header-auth`), 32 bytes. Verified in constant time after a successful VMK unwrap.

### Parser obligations

Reject without crashing: bad magic, truncation, trailing bytes, oversized input, unknown KDF/algorithm ids, salt/KDF parameters outside the floors/ceilings above, wrapped-key length ≠ 32, nonzero feature flags, unsupported header-auth version, invalid version pairs. Rejection happens **before** any Argon2 memory allocation.

## Durability

Writes are: temp file in the same directory → `F_FULLFSYNC` (fallback `fsync`) → chmod 0600 → re-read and byte-compare → atomic rename. macOS gives no portable directory-fsync guarantee after rename; this residual window is accepted and documented. Stale `.zyquo-tmp-*` files are swept at startup.

## Manifest, records, attachments, journal **(M2/M6)**

To be specified when implemented. Commitments already fixed by design: the manifest is encrypted (names and counts are sensitive) and chains previous-manifest digests for rollback detection; every record file is independently authenticated with per-record DEKs and AAD binding (object type 2, its UUID, its revision); attachments use chunked authenticated encryption with per-chunk AAD (attachment UUID + chunk index).
