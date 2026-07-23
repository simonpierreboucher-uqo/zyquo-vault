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
| 98+S+C | 4 | feature flags | bit 0x1 = recovery section present; any other bit ⇒ reject |
| … | 0 or R | recovery section (only if flag 0x1) | see below |
| … | 1 | header-auth version | 1 = HMAC-SHA256 |
| … | 32 | header-auth tag | HMAC-SHA256 over the header body: every byte before the auth-version byte |
| … | — | end | trailing bytes ⇒ reject |

**Recovery section** (flag 0x1, §7.1): salt length (1 byte, 16…64) ‖ salt ‖ nonce (12) ‖ ciphertext length (4, must be 32) ‖ recovery-wrapped VMK ‖ GCM tag (16). The wrap key is HKDF-SHA256(recovery key, salt, info `zyquo-vault/v1/recovery-kek`); AAD uses object type 6 with revision 0. The recovery key itself is 32 CSPRNG bytes shown once as `ZQRK-` + 13 groups of 4 Crockford-base32 characters.

With the default S = 16, C = 32 and no recovery section the header is 183 bytes; with a recovery section, 264 bytes.

Wrapped-VMK AAD: the canonical 57-byte AAD structure (see `docs/cryptography.md`) with vault UUID, object UUID = vault UUID, object type 1, schema version = format version, revision 0, algorithm 1.

Header-auth key: HKDF-SHA256(VMK, salt = vault-UUID bytes, info = `zyquo-vault/v1/header-auth`), 32 bytes. Verified in constant time after a successful VMK unwrap.

### Parser obligations

Reject without crashing: bad magic, truncation, trailing bytes, oversized input, unknown KDF/algorithm ids, salt/KDF parameters outside the floors/ceilings above, wrapped-key length ≠ 32, nonzero feature flags, unsupported header-auth version, invalid version pairs. Rejection happens **before** any Argon2 memory allocation.

## Durability

Writes are: temp file in the same directory → `F_FULLFSYNC` (fallback `fsync`) → chmod 0600 → re-read and byte-compare → atomic rename. macOS gives no portable directory-fsync guarantee after rename; this residual window is accepted and documented. Stale `.zyquo-tmp-*` files are swept at startup.

## Record envelope (`records/<uuid>.zyqrec`)

Independently authenticated; integers big-endian; payload ≤ 16 MiB.

| Offset | Size | Field | Constraints |
|---|---|---|---|
| 0 | 4 | magic `"ZYQR"` | exact |
| 4 | 4 | envelope version | 1 |
| 8 | 16 | record UUID | must equal the filename stem |
| 24 | 4 | schema version | cross-checked against the manifest entry |
| 28 | 8 | revision | cross-checked against the manifest entry |
| 36 | 12 | DEK-wrap nonce | |
| 48 | 4 | DEK ciphertext length | must be 32 |
| 52 | 32 | DEK ciphertext | wrapped by the `record-wrapping` HKDF subkey |
| 84 | 16 | DEK-wrap GCM tag | |
| 100 | 12 | payload nonce | |
| 112 | 8 | payload ciphertext length N | ≤ 16 MiB |
| 120 | N | payload ciphertext | `VaultItem` JSON under the record's random DEK |
| 120+N | 16 | payload GCM tag | |

Both seals use the canonical AAD (vault UUID, record UUID, type 2, schema version, revision) under different keys. A record whose revision or schema version disagrees with the manifest is treated as corrupted — a substituted stale file is never silently accepted. The item JSON's `id` must equal the record UUID.

## Manifest (`vault.manifest`)

| Offset | Size | Field | Constraints |
|---|---|---|---|
| 0 | 4 | magic `"ZYQM"` | exact |
| 4 | 4 | manifest format version | 1 |
| 8 | 8 | generation | monotonically increasing; feeds the AAD |
| 16 | 12 | nonce | |
| 28 | 8 | ciphertext length N | ≤ 8 MiB |
| 36 | N | ciphertext | JSON payload, `manifest-protection` HKDF subkey |
| 36+N | 16 | GCM tag | |

AAD: (vault UUID, vault UUID, type 4, schema 1, revision = generation). The encrypted payload holds: vault UUID and generation (both must match the outer values), record and attachment inventories `{id, revision, schemaVersion}`, tombstones `{id, deletedAt}`, last transaction UUID, SHA-256 digest of the previous manifest file (rollback-detection chain, verifiable against backups), and the update timestamp. Names and counts are ciphertext by design.

## Transaction journal (`journal/<txid>.zyqjournal`)

Plain JSON, **no plaintext secrets** — transaction UUID, operation (`put`/`delete`), record UUID, previous/new manifest generation, timestamp. The atomic manifest replacement is the commit point:

- **put:** journal → write `records/<uuid>.zyqrec.pending` → replace manifest (COMMIT) → rename pending over final → delete journal.
- **delete:** journal → replace manifest without the entry, adding a tombstone (COMMIT) → delete record file → delete journal.

Recovery on open, per surviving entry: manifest generation ≥ entry's new generation ⇒ committed ⇒ roll forward (finish the rename/deletion); otherwise ⇒ roll back (remove the pending file). The last known valid state is never auto-discarded.

## Encrypted export (`.zyquoexport`)

Self-contained container protected by its **own** password (may differ from the vault's). Integers big-endian.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `"ZYQX"` |
| 4 | 4 | format version (1) |
| 8 | 16 | export UUID |
| 24 | 1 | Argon2id salt length S (16…64) |
| 25 | S | salt |
| 25+S | 4+4+4+1 | Argon2id memory KiB / iterations / parallelism / output length (validated against the same floors/ceilings before derivation) |
| … | 12 | nonce |
| … | 8 | ciphertext length N |
| … | N | ciphertext — JSON `{exportedAt, items, folders}` |
| … | 16 | GCM tag |

Key: Argon2id(password, salt) → 256-bit KEK. AAD: canonical structure with vault UUID = object UUID = export UUID, object type 5, revision 0. Wrong password and corruption are indistinguishable on open. Plaintext exports (JSON/CSV) exist only behind the UI's typed-confirmation warning flow and are documented as unprotected.

## Lock file (`lock`)

Plain JSON: `{pid, processName, acquiredAt}`. A lock with a live owner PID — even this process — rejects opening (`fileLocked`). A lock is reclaimed only when its PID provably no longer exists (`kill(pid,0)` → ESRCH), or when unreadable **and** older than 24 h. A lock file is never deleted merely because it exists.

## Attachments (`attachments/<uuid>.zyqatt`)

Chunked authenticated encryption; files are processed in chunks (default 1 MiB plaintext), never whole-file in memory. Integers big-endian.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `"ZYQA"` |
| 4 | 4 | format version (1) |
| 8 | 16 | attachment UUID (must equal filename stem) |
| 24 | 4 | schema version (1) |
| 28 | 12 | DEK-wrap nonce |
| 40 | 4 | DEK ciphertext length (must be 32) |
| 44 | 32 | DEK ciphertext — wrapped by the `attachment-wrapping` HKDF subkey |
| 76 | 16 | DEK-wrap GCM tag |
| 92 | … | chunk frames: `UInt32 ctLen ‖ nonce(12) ‖ ciphertext ‖ tag(16)` |
| … | … | metadata frame (same framing; JSON under the DEK) |
| end−8 | 8 | metadata frame offset |

AAD: canonical structure, object type 3 (`attachmentChunk`), with the **revision slot carrying the section index** — chunk *i* → *i* (0-based), metadata → 2⁶⁴−2, DEK wrap → 2⁶⁴−1. A chunk that is modified, truncated, reordered, or transplanted from another attachment fails authentication; ordering and count are additionally pinned by the encrypted metadata (`chunkCount`, `totalPlaintextSize`, SHA-256 over the whole chunk region). The original filename and MIME type live only inside the encrypted metadata.

Decryption goes to a vault-controlled `.decrypted-tmp/` directory (0700/0600), destroyed on lock/close and swept at open after abnormal termination. No partial plaintext is ever left on failure.

## Backups (`backups/<iso-stamp>-g<generation>/`)

A backup is a snapshot of `vault.header`, `vault.manifest`, `records/*`, and `attachments/*` — every file already independently encrypted and authenticated — plus a plaintext, non-secret `backup.info` (vault UUID, created-at, generation, counts, SHA-256 per file). **A backup is not valid until verified**: creation runs digest checks plus full cryptographic verification (header HMAC, manifest decryption, every record and attachment authenticated) and deletes the copy on any failure. Retention default: last 10, one per day × 7, one per week × 4. Restore always copies into a **new** vault directory; the active vault is never overwritten.
