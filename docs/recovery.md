# Recovery

There is no server and no Keychain, so a forgotten master password is unrecoverable **unless** the user opts in at vault creation.

## Implemented (M3)

- **Recovery key:** 32 CSPRNG bytes, displayed once as `ZQRK-` + 13 groups of 4 Crockford-base32 characters (I/L/O/U excluded; parsing forgives o→0, i/l→1 misreadings). HKDF-SHA256 with a per-vault salt derives the recovery KEK, which holds a second AEAD wrap of the VMK in the header (feature flag 0x1, AAD object type 6). The creation ceremony requires re-typing the final key group before the vault is created; declining the key entirely is allowed and respected.
- **Unlock via recovery key** from the lock screen ("I forgot my password…"), with the same fail-closed, deliberately ambiguous error as the password path and the same in-process rate limiting.
- **Rotation** (Settings → rotate): installs a fresh key, verifies it opens the vault, and invalidates the old one. **Removal** deletes the wrap.
- Password change never invalidates the recovery key (both wrap the same VMK).

## Not yet implemented

- Printable recovery sheet (M5 polish) and the separately encrypted offline recovery package.

Plain statements the UI makes: recovery key + vault file = full access — store it like cash; losing both password and key = permanent loss. No security questions. No email recovery.
