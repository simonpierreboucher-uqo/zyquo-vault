# CLAUDE.md — Zyquo Vault

> **Version 2 of this specification.** This document is the single source of truth for building Zyquo Vault. When any instruction elsewhere (comments, older docs, generated code) conflicts with this file, this file wins. When two rules inside this file appear to conflict, the more security-conservative interpretation wins, and the conflict must be documented in `docs/decisions/`.

---

## 0. Reading guide for Claude

This file uses three normative levels, in the spirit of RFC 2119:

* **MUST / MUST NOT** — hard requirement. Violating it means the milestone is not done.
* **SHOULD / SHOULD NOT** — strong default. Deviating requires a written justification in `docs/decisions/ADR-XXXX.md`.
* **MAY** — allowed option.

Sections are ordered so that reading them top to bottom gives you: identity → non-negotiables → design system → cryptography → storage → domain → UX flows → features → engineering quality → testing → milestones → execution behavior.

---

## 1. Project identity

You are building **Zyquo Vault**: a native, local-first, offline password manager and encrypted secret vault for macOS.

**Stack (MUST):**

* Swift (Swift 6 language mode where practical, strict concurrency)
* SwiftUI, with AppKit only where SwiftUI is genuinely insufficient
* Swift Package Manager as the canonical project definition
* CryptoKit for AEAD and HKDF
* Native macOS APIs only

**Delivery constraints (MUST):**

* Buildable, testable, packaged, and launched **entirely from the terminal**. Opening Xcode is never required. `xcodebuild` and `.xcodeproj` files are forbidden. Xcode Command Line Tools are allowed.
* **No Apple Keychain**, in any form, for any purpose (see §4.2).
* No Electron, no web wrapper, no embedded browser as the main UI.
* No cloud sync, browser extensions, accounts, or servers in v1. The local vault must be complete, reliable, tested, and documented first.

**Supported content types (v1):** logins, secure notes, API keys/credentials, software licenses, payment card metadata, identities, SSH key metadata, generic secrets, TOTP configurations, custom fields, tags, favorites, folders/collections, encrypted attachments, import/export, encrypted backups.

**Target platform:** macOS 15+, Apple Silicon primary, Intel kept possible if dependencies allow.

---

## 2. Product principles

1. **Local-first.** All data lives on the user's Mac. No secret, metadata, telemetry, identifier, or ciphertext ever leaves the machine. The app works fully offline, forever.
2. **No Keychain, ever** (§4.2). The vault implements its own encrypted format and persistence.
3. **Open, inspectable format.** The encrypted format is fully documented (`docs/vault-format.md`) to the level that an independent implementation could read a vault. Established primitives only — never invent a cipher, hash, MAC, RNG, or KDF.
4. **Secure by default.** Starts locked; auto-locks; clears clipboard; never logs secrets; never writes plaintext temp files it doesn't immediately control and destroy; authenticated encryption everywhere; fails closed on any integrity failure; never stores the master password.
5. **Honest about limitations.** No "military-grade" claims, no "unhackable", no implied Touch-ID persistence, no pretending memory erasure in Swift is perfect. Residual risks are documented, not hidden.
6. **Design excellence is a requirement, not a garnish.** Zyquo Vault must look and feel like a flagship native macOS app — calm, light, rounded, and meticulous (§3). A security tool people enjoy using is a security tool people actually use.

---

## 3. Design system — "Zyquo Soft Light"

This section is normative. The visual identity is a first-class deliverable with its own module, tokens, tests, and review gate. **Do not improvise per-view styling.** Every color, radius, spacing, font, and shadow in the UI must come from the token system defined here.

### 3.1 Design direction

* **Light theme is the primary, default, and reference theme.** Every screen is designed light-first and must be flawless in light mode. Dark mode is supported via the same token system, derived later, and must never degrade the light experience.
* **Aesthetic:** soft, rounded, airy, precise. Think "a beautifully machined object with soft edges": generous whitespace, continuous rounded corners everywhere, gentle layered surfaces, one confident accent color, zero visual noise.
* **Signature element:** the **Vault Card** — every item, panel, sheet, and the lock screen itself is expressed as a softly rounded, softly elevated card floating on a warm off-white canvas. This single motif carries the identity; everything else stays quiet.
* **Emotional target:** trust through calm. No aggressive reds, no dense chrome, no gradients-for-decoration, no glassmorphism kitsch. Security states are communicated with clarity, not alarm.

### 3.2 Design tokens (MUST live in `Sources/ZyquoVaultDesign/`)

Create a dedicated `ZyquoVaultDesign` target containing all tokens, modifiers, and reusable components. UI code MUST NOT contain raw hex values, raw point sizes for radius/spacing, or ad-hoc shadows. A lint script (`scripts/audit-design-tokens.sh`) SHOULD flag raw `Color(red:...)`, `.cornerRadius(` with literal numbers, and hardcoded hex strings inside `ZyquoVaultUI`.

**Color palette — light theme (reference values, tune only with justification):**

| Token | Value | Usage |
|---|---|---|
| `canvas` | `#F7F6F3` | App background (warm off-white, never pure white) |
| `surface` | `#FFFFFF` | Cards, panels, sheets |
| `surfaceRaised` | `#FFFFFF` + elevation.2 | Popovers, menus, floating cards |
| `surfaceSunken` | `#EFEEEA` | Wells, input backgrounds, code/secret fields |
| `inkPrimary` | `#1C1B1A` | Primary text (near-black, warm) |
| `inkSecondary` | `#6E6B66` | Secondary text, labels |
| `inkTertiary` | `#A5A29C` | Placeholders, disabled, metadata |
| `accent` | `#3D6BFF` → refine to a proprietary "Zyquo Blue" | Primary actions, selection, focus |
| `accentSoft` | `accent @ 10–12% on surface` | Selected rows, chips, hover fills |
| `positive` | `#2E9E6B` | Success, "copied", strong passwords |
| `caution` | `#C98A2B` | Warnings, aging passwords |
| `critical` | `#C94F3D` | Destructive actions, integrity failures (muted, not fire-alarm red) |
| `sealGold` | `#B9975B` | Reserved: favorites star, recovery-key ceremony accents |
| `hairline` | `ink @ 8%` | Separators (use sparingly; prefer spacing over lines) |

Rules:

* Contrast MUST meet WCAG AA (≥ 4.5:1 body text, ≥ 3:1 large text/icons) — add an automated token contrast test.
* `critical` is used only for genuinely destructive/integrity contexts. Errors are explained calmly (§3.8).
* Semantic colors only in UI code (`.foregroundStyle(Zyquo.color.inkSecondary)`), never role-free names like "blue".

**Corner radius — continuous curves everywhere (MUST):**

All rounded shapes use `RoundedRectangle(cornerRadius:style:.continuous)` (squircle-style curvature). Radius scale:

| Token | Value | Usage |
|---|---|---|
| `radius.xs` | 6 | Tags, badges, small chips |
| `radius.s` | 10 | Buttons, inputs, list rows |
| `radius.m` | 14 | Cards, item rows, sidebar selection |
| `radius.l` | 20 | Panels, detail cards, sheets |
| `radius.xl` | 28 | Lock screen card, onboarding cards, modals |
| `radius.full` | ∞ | Pills, avatars, TOTP countdown ring |

Nested radii MUST be concentric: inner radius = outer radius − inset padding (document the helper that computes this). Never mix sharp and rounded corners on the same element.

**Spacing:** 4-pt base grid. Scale: 4, 8, 12, 16, 20, 24, 32, 40, 56. Section padding defaults: cards 16–20, panels 24, sheets 32. Whitespace is the primary grouping tool; hairlines are the fallback, not the default.

**Typography:**

| Role | Face | Notes |
|---|---|---|
| Display / vault name / lock screen | **SF Pro Rounded**, semibold | Rounded face reinforces the identity; use with restraint (titles only) |
| Body & UI | SF Pro Text | System sizes, Dynamic Type–compatible |
| Secrets, keys, TOTP, passwords | **SF Mono**, medium | Slashed zero; tabular digits; slightly increased tracking for concealed dots |
| Metadata / captions | SF Pro Text, `inkTertiary` | 11–12 pt |

Type scale MUST be defined once in the design module (e.g. `Zyquo.type.title`, `.body`, `.mono`, `.caption`) and used everywhere. TOTP codes render grouped (`123 456`) in `mono` at a large size with a countdown ring in `accent`.

**Elevation (soft, diffuse — never harsh):**

| Level | Shadow | Usage |
|---|---|---|
| 0 | none | Flat content on canvas |
| 1 | y2 blur8 @ ink 6% | Cards at rest |
| 2 | y4 blur16 @ ink 8% | Hovered cards, popovers |
| 3 | y12 blur32 @ ink 12% | Sheets, lock card, modals |

**Motion:** subtle and physical. Standard spring (`response ~0.35, damping ~0.85`) for state changes; 150–200 ms ease-out for hovers; a single orchestrated moment for **unlock** (lock card gently scales/settles into the main window — this is the app's one theatrical animation). Reveal/conceal of secrets is a fast crossfade, never a slow flourish. `Reduce Motion` MUST replace all movement with opacity fades.

### 3.3 Component library (build these once, reuse everywhere)

`ZyquoVaultDesign/Components/` MUST provide at minimum:

* `ZyquoCard` — the signature surface (radius.m/l, elevation.1, surface fill).
* `ZyquoButton` — primary (accent fill, white label), secondary (surfaceSunken fill), destructive (critical, confirm-gated), quiet (text-only). All radius.s, all with pressed/hover/focus states.
* `ZyquoTextField` / `ZyquoSecureField` — surfaceSunken well, radius.s, focus ring in `accent @ 40%` (2 pt, outside), inline validation below in caption size.
* `ZyquoSecretField` — mono, concealed by default (dots, not asterisks), eye toggle, copy button with "Copied ✓" transient state and clipboard-timer indicator.
* `ZyquoTag` — pill, accentSoft fill.
* `ZyquoStrengthMeter` — segmented, rounded, `critical→caution→positive`, with entropy label ("estimate").
* `ZyquoTOTPRing` — circular countdown, accent stroke, turns `caution` under 5 s.
* `ZyquoEmptyState` — icon (SF Symbol, hierarchical rendering), one-line explanation, one clear action. Empty screens are invitations, never dead ends.
* `ZyquoBanner` — inline info/warning/critical banners (radius.s, soft tinted fills), used instead of intrusive alerts wherever possible.
* `ZyquoListRow` — item row: leading rounded type-icon tile (radius.xs, accentSoft), title, subtitle in `inkSecondary`, trailing metadata; selection = accentSoft fill with radius.m, not a full-bleed rectangle.

Icons: SF Symbols only, hierarchical/palette rendering, consistent weight (regular/medium). No third-party icon packs.

### 3.4 Key screens — layout specification

* **Lock screen:** canvas background; centered `ZyquoCard` at radius.xl, elevation.3, max-width ≈ 420 pt; app mark; vault name in Rounded semibold; secure field; unlock button full-width; quiet links below ("Open another vault…", "I forgot my password…"). Caps Lock warning appears inline in `caution`. During KDF: button morphs into an indeterminate capsule progress ("Deriving keys…"); the field stays visible; the UI never freezes.
* **Main window:** `NavigationSplitView`, three columns — Sidebar (220–260 pt) | Item list (300–360 pt) | Detail. Sidebar on canvas with rounded selection pills; list and detail are card-like surfaces with radius.l on the content region, floating on canvas with comfortable gutters (the "cards on a desk" feeling). Native toolbar: search field, New Item (accent), Lock (⌘L), overflow menu.
* **Item detail:** header card (icon tile, title, tags, favorite `sealGold` star), then grouped field cards. One secret revealed at a time by default. Password age, history, attachments each in their own card section.
* **Editor:** sheet at radius.xl or inline editing per design decision (write an ADR); dynamic fields reorderable by drag with soft lift (elevation.2 while dragging); unsaved-changes guard.
* **Onboarding / vault creation:** a sequence of centered radius.xl cards — one decision per card, plain language, generous type. The recovery-key step is the ceremony moment: `sealGold` accents, print/save actions, mandatory confirmation of selected word groups.

### 3.5 Design quality gates (MUST)

* A `docs/design-system.md` documenting tokens, components, and do/don'ts, with screenshots per milestone.
* Every UI milestone ends with a self-critique pass against this section: remove one decoration, check radii concentricity, check contrast, check empty/error/loading states exist for every screen.
* No screen ships with: raw hex in view code, mixed corner styles, pure-white full-bleed backgrounds, harsh shadows, more than one accent color competing, or center-aligned body paragraphs.

### 3.6 Dark mode

Same token names, dark values (canvas ≈ `#161514`, surface ≈ `#1E1D1B`, ink inverted, accent slightly desaturated). Implemented only after light mode is complete and reviewed. System / Light / Dark setting; **default: Light**.

### 3.7 Accessibility (MUST)

VoiceOver labels/hints on every control; concealed values are NOT exposed to accessibility APIs until explicitly revealed (test this); full keyboard navigation with visible focus rings (accent, 2 pt); Reduce Motion honored; Increase Contrast honored (tokens provide high-contrast variants); resizable text where applicable.

### 3.8 Voice & microcopy

Sentence case everywhere. Plain verbs ("Unlock", "Copy password", "Create vault"). Buttons say what happens; the action keeps its name through the flow ("Export…" → "Exported"). Errors state what happened and what to do next, calmly, without apologizing and without leaking internals: *"The password is incorrect or the vault file is damaged. Try again, or open Recovery."* Never blame the user. Warnings about real limitations (Touch ID, forgotten passwords, plaintext export) are written in honest, human language — clarity is part of the security model.

---

## 4. Non-negotiable security rules

### 4.1 Engineering standard & public warning

This app stores highly sensitive data. It MUST be structured for future independent cryptographic review, audit, pen-testing, fuzzing, static analysis, and reproducible-build review. README MUST carry (until a professional audit):

> Zyquo Vault is under active development. Until the storage format and cryptographic implementation have undergone an independent security audit, it should not be used as the sole storage location for irreplaceable production credentials.

### 4.2 Keychain prohibition (absolute)

MUST NOT use, directly or transitively: Keychain Services, Security.framework keychain APIs (`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`, `kSecClass*`), KeychainAccess, Locksmith, any keychain wrapper, iCloud Keychain, Shared Web Credentials. No dependency may introduce Keychain silently. `scripts/audit-forbidden-apis.sh` MUST scan sources **and resolved dependencies**, distinguish executable code from documentation, and fail CI on hits. Using the OS secure RNG (`SecRandomCopyBytes`) is explicitly allowed — the prohibition targets keychain *storage*, not the random API.

### 4.3 Forbidden shortcuts (fail CI / reject the change)

Never: store the master password; store the VMK unencrypted; put secrets or session keys in `UserDefaults`; obfuscation or Base64 as "security"; ECB; CBC without a correct separate MAC; static keys; nonce reuse; keys derived from device serials; keys hidden in source; secrets in logs; plaintext search index on disk; any network transmission of vault data; auto-loading remote resources in notes; insecure temp files; disabled tag verification; ignoring write errors; continuing after integrity failure; `try!`/force-unwrap/`fatalError` in crypto or storage paths; marketing claims ("military-grade", "unhackable"); implying Touch ID persistence; adding dependencies without license/maintenance review.

---

## 5. Cryptographic design

### 5.1 Objectives & explicit non-goals

Protects against: theft of the encrypted vault; offline password guessing; modification, substitution, or (detectably) deletion of records; header manipulation; nonce reuse; partial writes; backup corruption; accidental plaintext exposure.

Does NOT protect against (document in `docs/threat-model.md`): a compromised running session, malware with process-memory access, malicious kernel, screen capture while unlocked, hardware keyloggers, password entry on a compromised machine.

### 5.2 Master password handling

Never stored, written to disk, logged, or retained past key derivation. Handle it in a dedicated sensitive type; convert to UTF-8 bytes as late as possible; overwrite mutable buffers after use; minimize `String` lifetime. Document honestly that Swift cannot guarantee perfect erasure (copies, ARC, optimizer, immutable string internals). Where practical, keep password/key buffers in `mlock`-able allocations via the `SecureBytes` type (§8.1) — best-effort, documented as such.

### 5.3 KDF — Argon2id

Argon2id derives the Password Key-Encryption Key (PKEK). Requirements: unique random salt per vault (≥ 16 bytes); configurable memory/iterations/parallelism; 32-byte output; parameters stored in the header; upgradeable via migration; **calibrated on the device at vault creation** targeting ~500–1000 ms unlock, with enforced minimum floors (never below e.g. 64 MiB / t=3 on Apple Silicon — pick and document exact floors). Suggested modern range: 64–256 MiB, t=3–5, p=1–4. User may choose a stronger profile.

Forbidden: single-hash SHA-256, MD5, SHA-1, unsalted PBKDF2. PBKDF2-HMAC-SHA-256 with high iterations is allowed ONLY as an explicit, documented temporary compatibility mode if Argon2id is genuinely unavailable.

Implementation selection procedure (MUST, in order): research maintained Swift bindings to the **official Argon2 reference implementation**; verify license, maintenance, internal secret-copy behavior; pin the version; add official known-answer vectors. If nothing qualifies, vendor the official Argon2 C reference in a system-library target with a minimal Swift wrapper that validates parameters, rejects DoS-scale memory requests, returns typed errors, never logs inputs, and uses constant-time comparison where relevant.

### 5.4 Key hierarchy

```
Master password + per-vault salt + Argon2id params
  → PKEK (exists only during unlock / password change / creation)
      → AEAD-unwraps the random 256-bit Vault Master Key (VMK), wrapped in the header
          → HKDF-SHA256 domain-separated subkeys, contexts like:
              zyquo-vault/v1/record-wrapping
              zyquo-vault/v1/attachment-wrapping
              zyquo-vault/v1/manifest-protection
              zyquo-vault/v1/backup-protection
              zyquo-vault/v1/search-session
              → per-record / per-attachment random 256-bit DEKs,
                wrapped by the relevant subkey
                  → AEAD-encrypted payloads
```

Rules: the VMK is random, never password-derived, wrapped with the PKEK using AEAD with authenticated header fields as associated data. Password change = re-wrap the VMK (new salt, new PKEK), atomically, verify reopen, never re-encrypt records. Each HKDF context is unique; never reuse a subkey across purposes. Per-record DEKs allow rewriting one record without touching the vault. Full rekey (new VMK, re-wrap everything) is a separate, crash-safe, advanced operation (post-M2).

### 5.5 AEAD

One canonical algorithm for v1: **AES-256-GCM via CryptoKit** (hardware-accelerated on Apple Silicon); ChaCha20-Poly1305 acceptable alternative — pick one, record an ADR. Every encryption uses a fresh CSPRNG nonce; never timestamp- or counter-derived unless counter lifecycle and crash-consistency are formally proven (don't). Associated data MUST bind every ciphertext to at least: vault UUID, object UUID, object type, schema version, revision, algorithm identifier. Define the exact canonical AAD encoding in `docs/cryptography.md` — a byte-level table, not prose. Fail closed on any authentication failure; never return partial plaintext.

### 5.6 Randomness, comparisons, verification

* CSPRNG only: `SecRandomCopyBytes` / `SystemRandomNumberGenerator` / CryptoKit key generation, wrapped in a `SecureRandom` abstraction injectable for deterministic tests. Never: raw `arc4random` without review, PRNGs, timestamps, UUID text, or user identifiers as key material.
* Constant-time comparison utility for MACs/verifiers, with tests.
* Password verification = successful authenticated unwrap of the VMK. Internally distinguish wrong-password vs corruption; user-facing message stays deliberately ambiguous (§3.8). Detailed diagnostics only via a local sanitized export that never contains secret material.

---

## 6. Vault storage architecture

### 6.1 Location & layout

Default: `~/Library/Application Support/Zyquo Vault/`

```
vaults/<vault-uuid>/
  vault.header        # versioned, authenticated
  vault.manifest      # encrypted + authenticated inventory
  records/<uuid>.zyqrec
  attachments/<uuid>.zyqatt
  journal/            # transaction journal (no plaintext secrets)
  backups/
  lock                # process lock metadata
preferences/          # non-sensitive only
diagnostics/          # sanitized only
```

`UserDefaults` MAY hold only non-sensitive prefs (window state, theme, durations). Never passwords, keys, seeds, secret fields, decrypted search content, or vault contents.

### 6.2 Directory-based format (v1) — rationale

Simplifies atomic per-record replacement, attachments, backups, recovery, corruption isolation, migration, testing. **Every record file is independently authenticated.** The manifest (itself encrypted — names and counts are sensitive) lists expected records + revisions; missing or unexpected files trigger an integrity warning, never silent acceptance.

### 6.3 Header

Versioned canonical serialization — a specified binary format or canonical CBOR. Plain JSON is forbidden for authenticated structures unless canonicalization is implemented and tested (prefer not). Contents: magic bytes, format version, minimum reader version, vault UUID, timestamps, KDF id + Argon2id salt/memory/iterations/parallelism/output length, key-wrap algorithm id, wrapped-VMK (nonce, ciphertext, tag), optional wrapped recovery copy, header-auth version, feature flags, migration state. Parser MUST reject: unknown mandatory fields, bad lengths, unsupported algorithms, DoS-scale KDF params, below-floor params, duplicates, truncation, invalid version transitions — without crashing (fuzz target, §12).

### 6.4 Manifest

Encrypted + authenticated: vault UUID, manifest version, generation number, record & attachment inventories with revisions, tombstones, last committed transaction id, previous-manifest digest (rollback detection chain), timestamps. Must detect: missing/unexpected records, rollback where practical, partial transactions, attachment mismatches.

### 6.5 Atomic writes, permissions, locking, journal

* **Atomic updates only:** serialize → encrypt → write temp file in same directory → flush → set 0600 → validate by re-reading → atomic rename → atomic manifest update → clean temps. Document macOS fsync/`F_FULLFSYNC` and directory-sync limitations. Must recover from: kill mid-write, power loss, partial update, stale temps, failed manifest swap.
* **Permissions:** 0700 dirs / 0600 files; validated at startup; warn on unsafe permissions; never a substitute for encryption.
* **Locking:** process-level write lock with owner metadata; stale-lock detection by PID + age (never delete a lock just because it exists); read-only recovery mode; clear user messaging.
* **Journal:** per multi-file transaction — UUID, operation, affected records, expected/new generation, temp paths, commit state, timestamp. No plaintext secrets in the journal. On startup: inspect → detect incomplete transactions → validate files → roll forward or back safely → **never** auto-discard the last known valid state.

---

## 7. Recovery, deletion, backups

### 7.1 Recovery model

No server, no Keychain ⇒ a forgotten master password is unrecoverable unless the user opts in at creation:

* **Recovery key:** generate a high-entropy random key → derive a recovery KEK → wrap the VMK a second time into the header → show the key **once** with a printable recovery sheet → require confirmation of selected word groups. Zyquo never stores it in plaintext. User may decline.
* **Optional offline recovery package** (separately encrypted).
* Document plainly: recovery key + vault file = full access; losing both password and key = permanent loss. **No security questions. No email recovery.**

### 7.2 Trash & deletion honesty

Delete → encrypted trash (restore / permanent delete / empty / auto-purge after configurable period). Permanent delete: remove from manifest, delete ciphertext, invalidate wrapped keys, note that old backups may still hold the encrypted item. Be explicit in UI + docs: SSD wear-leveling, APFS snapshots, and backups make physical erasure unguaranteeable — **encryption + key destruction is the real control.**

### 7.3 Backups

Always encrypted. Manual + automatic local backups; retention (default: last 10, daily×7, weekly×4); verification; restore preview; restore into a *separate* vault; never overwrite the active vault without confirmation. Backup = header + manifest + records + attachments + format metadata + integrity info. Never includes logs, caches, search index, temp plaintext, or session keys. **A backup is not valid until the app has automatically verified its structure and cryptographic integrity** — test restoration in CI.

---

## 8. In-memory security & sessions

### 8.1 `SecureBytes`

Mutable backing storage; redacted `description` (`<redacted>`); not `Codable` by default; explicit + best-effort deinit zeroization; scoped access closures; copy-minimizing API; `mlock` best-effort where practical. Document Swift's limits honestly.

### 8.2 `VaultSession` actor

An `actor VaultSession` owns the VMK/subkeys and mediates unlock, lock, CRUD, search, password change, backup, export. UI views never own key material. Tracks unlock time and activity; enforces auto-lock. Bounded decrypted-record cache, cleared on: manual lock, auto-lock, sleep, screen lock, fast user switch, app termination, vault change, memory pressure.

### 8.3 Lock triggers & lock procedure

Lock on: manual (⌘L), inactivity timeout, Mac sleep, screen lock, app quit, configurable background time, repeated sensitive-operation failures. Locking MUST: stop sensitive operations, zero VMK + subkeys, clear decrypted records + search index + revealed fields, clear owned clipboard values, delete decrypted temp files, cancel pending exports, and replace the UI with the lock screen. Hiding the UI while keys stay alive is forbidden.

### 8.4 Touch ID — honest limits

Without Keychain there is no persistent biometric unlock. Allowed: LocalAuthentication may **re-authorize an already-unlocked in-memory session** (re-open a visually locked UI, gate reveal/copy) while the process lives, if the user opts in. Forbidden: persisting the VMK, storing the password, hidden unlock tokens, or any UX implying biometrics survive a restart. After restart or VMK purge, the master password is required — say so plainly in the UI.

---

## 9. Domain model

Strongly typed, `Sendable`, versioned. `Codable` is a serialization step strictly inside the encrypt/decrypt boundary — never persisted unencrypted.

```swift
struct VaultItem: Identifiable, Codable, Sendable {
    let id: UUID
    var itemType: VaultItemType      // login, secureNote, apiCredential, softwareLicense,
                                     // paymentCard, identity, sshCredential, totp, genericSecret
    var title: String
    var subtitle: String?
    var fields: [VaultField]
    var notes: String?
    var tags: [String]
    var folderID: UUID?
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var revision: UInt64
    var attachmentIDs: [UUID]
}

struct VaultField: Identifiable, Codable, Sendable {
    let id: UUID
    var label: String
    var value: SensitiveFieldValue   // redacted debug description enforced
    var kind: VaultFieldKind         // plain, concealed, username, password, url, email,
                                     // phone, date, number, multiline, totpSeed, apiKey,
                                     // privateKey, publicKey, custom
    var isConcealed: Bool
    var isCopyable: Bool
}
```

**Metadata minimization (MUST):** title, username, URL, tags, folder, notes, passwords, custom fields, favorite status all live *inside* the encrypted payload. Only a random UUID and minimal structural fields (type id, schema version, revision, timestamps if needed for sync-free operation) remain observable — and anything observable is documented as observable in the threat model.

---

## 10. Features

### 10.1 First launch & vault creation

First launch: intro → local-first & no-account explanation → development-security warning → Create / Open / Import. Creation flow: name → master password + confirmation with strength guidance (length over composition rules; offer a generated passphrase; empty forbidden; no arbitrary "one symbol" rules) → unrecoverability explanation → recovery-key ceremony (§7.1, `sealGold` design moment) → Argon2id calibration with visible progress → generate VMK + IDs → write initial vault → **verify by actually reopening it** → create initial encrypted backup.

### 10.2 Unlock

Vault name, secure field with reveal toggle, unlock button, "open another vault", recovery link, Caps Lock warning, KDF progress, calm error message. Derivation off the main actor; UI stays responsive. In-process rate limiting on repeated attempts (acknowledging offline attacks are unaffected).

### 10.3 Item browsing & editing

Three-pane layout per §3.4. Detail: concealed by default, one reveal at a time, copy with confirmation + clipboard timer chip, password age, history if available, edit/duplicate/trash, attachments, TOTP with countdown ring. Editor: dynamic reorderable fields, custom fields, conceal toggles, generator integration, tags, folder picker, Markdown notes, attachments, validation, unsaved-change guard.

### 10.4 Password generator

Modes: random, memorable passphrase, PIN, safe custom pattern. Options: length, character classes, exclude-ambiguous, minimum categories; passphrase word count/separator/caps/digits/word-list language. CSPRNG with rejection sampling (no modulo bias; audit `Int.random` usage). Entropy estimate labeled as an estimate. No absolute claims.

### 10.5 TOTP (RFC 6238)

SHA-1 (compat), SHA-256, SHA-512; 6/8 digits; configurable period; `otpauth://` import; safe QR import if implemented; manual entry. Seeds encrypted like any secret; generated codes never stored or logged; local time source with drift warning; **RFC test vectors mandatory.**

### 10.6 Search

Only while unlocked: in-memory index built from decrypted non-secret fields (title, username, URL hostname, tags, folder, non-secret labels) after unlock; bounded; never written to disk; cleared on lock; rebuilt on unlock. No plaintext tokens on disk, no Spotlight integration of sensitive records, no searching of password values or TOTP seeds.

### 10.7 Clipboard

Clipboard service: write value → record a fingerprint → start timer (default 30 s; options 10/30/60/120/never) → clear **only if the clipboard still holds the same value** → also clear on lock. Never log clipboard contents. Use transient pasteboard types where supported without assuming respect. Warn about third-party clipboard managers; offer a reveal-only mode that disables copying. The UI shows a small countdown chip after copying ("Clears in 27 s").

### 10.8 Attachments

Per attachment: UUID → random DEK → **streamed/chunked authenticated encryption** (never whole-file in memory for large files): each chunk carries sequence number, unique nonce, tag, and AAD binding (attachment UUID + chunk index); final metadata includes total size, chunk count, ciphertext digest, and encrypted original filename + MIME type. DEK wrapped by the attachment subkey. Opening decrypts to an app-controlled temp dir only when unavoidable: 0600, deleted promptly, on lock, on quit, and swept at startup after abnormal termination. Warn that external apps may cache their own copies.

### 10.9 Import / Export

**Import (v1):** generic CSV, Bitwarden JSON/CSV, 1Password formats where legally/technically possible, KeePass XML/CSV where practical, browser CSV, Zyquo encrypted export. Flow: select → sensitivity warning → parse locally → preview + validation warnings → category mapping → duplicate detection → temp transaction → atomic commit → offer source deletion (with SSD honesty). Never upload, never log fields. Sanitized fixtures only.

**Export:** preferred = encrypted Zyquo export (versioned, authenticated, optionally separately password-protected, documented). Plaintext (JSON/CSV/Markdown) only behind: strong warning, explicit confirmation, unlocked vault, non-predictable location, offered immediate deletion, never automatic, never hidden inside backups.

### 10.10 Secure-note Markdown

Headings, lists, checklists, tables, code, quotes, links, rules, inline formatting. Rendering: no script execution; if HTML is used internally — JS disabled, output sanitized, remote resources blocked, no auto network, no image loading without explicit consent, no full embedded browser. Edit / preview / split modes. Source stays encrypted.

### 10.11 Settings (grouped)

* **Security:** auto-lock duration, lock on sleep / screen lock / inactive, clipboard duration, require password before export/settings changes, session Touch-ID reauthorization toggle, conceal-by-default.
* **Appearance:** System/Light/Dark (default Light), densities, monospaced secrets, note theme.
* **Vault:** locations, backup frequency/retention, validate now, change master password, rotate recovery key, full rekey (advanced), export, import.
* **Advanced:** format version, KDF parameters + recalibrate, sanitized diagnostics export, permission check, verify all records, open vault directory, read-only recovery mode.

### 10.12 Keyboard shortcuts

⌘N new, ⌘F search, ⌘L lock, ⌘, settings, ⌘S save, ⌘E edit, ⌫ trash, ⌘1–4 sections, ⌘⇧C copy password, ⌘⇧U copy username, ⌘⇧T copy TOTP. Secret-copying shortcuts configurable.

### 10.13 CLI (`zyquo-vault-cli`)

v1 safe commands only: `vault info|verify|backup|migrate <path>`, `format describe`. No secret-revealing commands in v1. Password never accepted as a CLI argument (visible in process lists) — secure prompt or stdin only; no env-var password by default; no shell-history leakage.

---

## 11. Engineering quality

### 11.1 Repository structure

```
ZyquoVault/
├── CLAUDE.md  README.md  SECURITY.md  CONTRIBUTING.md  LICENSE
├── Package.swift  Package.resolved  .gitignore  .swift-format
├── Resources/            # Info.plist, entitlements, assets, Localizable.xcstrings
├── Sources/
│   ├── ZyquoVaultApp/    # entry point, AppDelegate, commands, DI container
│   ├── ZyquoVaultDesign/ # §3: tokens, modifiers, components   ← NEW, mandatory
│   ├── ZyquoVaultUI/     # Root, Lock, Sidebar, ItemList, ItemDetail, ItemEditor,
│   │                     # Settings, ImportExport, Backup, Onboarding
│   ├── ZyquoVaultDomain/ # models, repositories, services, validation, errors
│   ├── ZyquoVaultCrypto/ # engine, KDF, hierarchy, SecureRandom, SecureBytes,
│   │                     # AEAD, header auth, errors
│   ├── ZyquoVaultStorage/# store, file, header, manifest, envelopes, attachments,
│   │                     # atomic writer, lock, backup, migration, errors
│   ├── ZyquoVaultImport/
│   └── ZyquoVaultCLI/
├── Tests/                # per-module + integration
├── scripts/              # §11.4
├── docs/                 # architecture, threat-model, vault-format, cryptography,
│   │                     # design-system, build-without-xcode, recovery, migrations,
│   └── decisions/        # ADR-0001, ADR-0002, …
└── Fixtures/             # ValidVaults/ CorruptedVaults/ ImportSamples/
```

Hard boundary: crypto, storage, domain, design, and UI stay in separate targets with one-way dependencies (`UI → Design + Domain + Storage`; `Storage → Crypto + Domain`; `Crypto` depends on nothing internal).

### 11.2 Concurrency & code rules

Actors for mutable shared state (`VaultSession`, `VaultRepository`, `CryptoService`, `BackupService`, `ImportService`, `ClipboardService`). No crypto/KDF/import/backup/index work on the main actor; SwiftUI must never block. Cancellation supported and MUST NOT leave partial files. Typed errors everywhere; no `try!`, force unwraps, `fatalError`, or silent catches in production paths. DI over singletons; no massive view models; no crypto or storage code inside views; no global mutable keys; no unowned detached tasks. Every cryptographic function documents: inputs, output format, key purpose, nonce rules, AAD, failure modes, memory lifetime.

### 11.3 Errors, logging, privacy

Domain-specific error enums (crypto: `invalidPasswordOrCorruptedVault`, `authenticationFailed`, `unsupportedAlgorithm`, `invalidNonce`, `invalidKeyLength`, `kdfFailure`, `malformedCiphertext`; storage: `vaultNotFound`, `permissionDenied`, `unsafePermissions`, `fileLocked`, `invalidHeader`, `invalidManifest`, `transactionRecoveryRequired`, `atomicWriteFailed`, `corruptedRecord(UUID)`). User messages never expose internals. Central OSLog layer with privacy annotations; prefer not logging secret-adjacent values at all. Diagnostic logs may include category, operation, timestamp, record UUID where acceptable, version, stage — never passwords, keys, VMK, plaintext, seeds, or clipboard contents. Repo test greps for suspicious logging of password/secret/token/apikey/totp/payload. **No telemetry, crash SDK, or analytics in v1.**

### 11.4 Build system & scripts (no Xcode)

`Package.swift` (swift-tools 6.0, macOS 15) defines: app executable, `ZyquoVaultDesign`, UI, domain, crypto, storage, import targets, CLI executable, unit + integration test targets, resources. Do not copy any example verbatim — produce a valid package for the final architecture.

Required scripts (each with clear errors and exit codes):

| Script | Job |
|---|---|
| `bootstrap.sh` | verify Swift/macOS/tools, resolve deps, create dirs; never installs with admin rights silently |
| `build.sh` | `swift build -c release` |
| `test.sh` | `swift test` (+ optional subsets, randomized corruption runs) |
| `lint.sh` | swift-format/SwiftFormat; fails in CI mode |
| `audit-forbidden-apis.sh` | §4.2 scan of sources + dependencies |
| `audit-dependencies.sh` | versions, licenses, forbidden packages, keychain symbols, unexpected network libs |
| `audit-design-tokens.sh` | §3.2 raw-value scan in UI target |
| `package-app.sh` | release build → `dist/Zyquo Vault.app` bundle (MacOS/, Resources/, Frameworks/ if needed, Info.plist with `dev.zyquo.vault`, entitlements) → permissions → ad-hoc `codesign --force --deep --sign -` → verify → `open` |
| `run.sh` | build + package + open |
| `generate-test-vault.sh`, `checksum-release.sh` | fixtures & release checksums |

No paid developer certificate assumed; document how Developer ID signing + notarization would be added later.

### 11.5 Dependency policy

Minimal. Each dependency documented (purpose, version pin, license, maintenance, security relevance, why stdlib is insufficient, update policy). Prefer Apple frameworks, small audited libraries, official algorithm implementations. Avoid big dependency trees, unmaintained packages, binary-only crypto SDKs, anything with analytics, silent network access, or internal Keychain use.

### 11.6 Format documentation & migrations

`docs/vault-format.md` MUST be independent-implementation-grade: byte order, magic, field types/lengths/limits, versions, required/optional fields, canonical serialization rules, KDF params, wrapped-key format, record envelope, attachment format, manifest, error handling, migration behavior — plus deterministic test vectors (fixed password/salt/VMK/nonce → expected wrapped VMK, ciphertext, tag), clearly marked as unsuitable for real vaults.

All persisted structures are versioned (format, record schema, attachment, manifest, KDF config). Migration = backup → validate → migrate in a separate transaction → validate every record → atomic commit → keep rollback until success → never silently downgrade security. Older versions fail safely on unsupported mandatory features.

---

## 12. Testing strategy (mandatory)

* **Crypto:** Argon2id + HKDF known-answer vectors; AES-GCM round-trip, tamper, wrong-key, nonce-validation; header-auth; record-binding; AAD-mismatch; constant-time comparison; SecureRandom interface; recovery-key; password-change.
* **Storage:** create/unlock/wrong-password; record CRUD + restore; corrupted/truncated header; corrupted manifest; missing/unexpected record; corrupted ciphertext; interrupted atomic write; stale temp; stale lock; unsafe permissions; backup + verified restore; migration; attachment encryption + corruption; concurrent-access rejection.
* **View-model / domain (no Xcode UI runner):** lock-state transitions, auto-lock timing, clipboard clearing, search, field validation, import mapping, settings validation, strength presentation, error presentation, accessibility of concealed fields (not exposed until revealed).
* **Property-based:** serialization round trips, random record generation, corruption detection, migration compatibility, generator constraints (character classes, no bias).
* **Fuzz / randomized:** header, manifest, record-envelope, import, `otpauth://` parsers, migration logic — all must reject malformed input without crashing.
* **Fixtures:** never real credentials; obvious markers (`example-password-not-real`, `test-api-key-000000`), labeled non-production.
* **Design tests:** token contrast (AA), token-usage lint, snapshot-style structural checks where feasible.

---

## 13. Documentation deliverables

`README.md` (identity, status + §4.1 warning, features, screenshots, exact terminal commands, no-Xcode instructions, storage location, format links, recovery explanation, Keychain prohibition, Touch ID limits, testing/packaging commands, contributing, disclosure). `SECURITY.md` (supported versions, reporting process + requested info, no-public-disclosure request, response process without unsupported time promises, crypto docs link, limitations, audit status, dependency + disclosure policy). `docs/`: architecture, threat-model (STRIDE-style: assets, actors, boundaries; per threat — risk, mitigation, residual risk, test coverage, future work), vault-format, cryptography, **design-system**, build-without-xcode, recovery, migrations, security-audit-checklist, decisions/ (ADRs).

---

## 14. Milestones & definitions of done

Each milestone is done only when: it builds via `swift build`, all its tests pass via `swift test`, `package-app.sh` produces a launchable `.app` (from M0 on), all audits pass, docs are updated, and — for UI milestones — the design gate of §3.5 has been run.

* **M0 — Foundation:** repo, SwiftPM targets (incl. `ZyquoVaultDesign` skeleton with tokens), CLI build, packaging script, minimal SwiftUI shell already styled with tokens (canvas + one `ZyquoCard`), test infra, lint, forbidden-API audit, doc skeleton. Acceptance: `swift build && swift test && ./scripts/package-app.sh && open "dist/Zyquo Vault.app"` all succeed, no Xcode.
* **M1 — Crypto core:** SecureRandom, SecureBytes, Argon2id wrapper + vectors, HKDF hierarchy, VMK wrapping, AES-GCM engine + AAD binding, tamper tests. **No substantial UI before crypto + tamper tests pass.**
* **M2 — Persistence:** header, manifest, record envelope, atomic writer, permissions, lock file, journal, CRUD, corruption-recovery tests.
* **M3 — Session & lock:** vault creation, unlock/lock, auto-lock, sleep/screen-lock observation, password change, recovery key, `VaultSession`, memory clearing. Lock screen built to §3.4 spec.
* **M4 — Core item UI:** sidebar, list, detail, editor, custom fields, favorites, tags, folders, trash, search — full §3 component library in use; design gate review with screenshots.
* **M5 — Security usability:** generator, clipboard service + countdown chip, TOTP + ring, Markdown notes, settings, accessibility pass, shortcuts.
* **M6 — Attachments & backups:** chunked encrypted attachments, automatic backups, verified restore, vault verification, diagnostics.
* **M7 — Import/export:** generic + browser CSV, Bitwarden, encrypted Zyquo export, plaintext-export warning flow.
* **M8 — Hardening & polish:** fuzzing, dependency + parser audits, performance profiling (unlock time, large vaults), memory review, dark-mode derivation from tokens, final design self-critique pass, security checklist, release packaging, audit preparation.

---

## 15. Acceptance criteria (release gate)

**Build:** `swift build` (debug + release) and `swift test` succeed; functional `.app` produced; zero Xcode GUI; deterministic documented commands.
**Security:** no Keychain; no persisted password or plaintext VMK; Argon2id; AEAD with unique random nonces and domain-separated keys; record + header tamper detection; encrypted attachments + backups; conditional clipboard clearing; lock on sleep; zero analytics; zero network requirement.
**Storage:** atomic writes; interrupted-transaction recovery; permission validation; documented format; migrations; last-known-valid state preserved; malformed input refused.
**Design & UX:** light theme flawless and default; every visual value token-sourced; continuous rounded corners throughout; component library used everywhere; AA contrast verified; keyboard + VoiceOver complete; responsive during KDF; honest recovery/Touch-ID/plaintext-export messaging; empty/error/loading states on every screen.
**Quality:** no real secrets in tests; no force unwraps in security paths; no secret logging; no leftover plaintext temps; unit + integration + corruption + fuzz coverage; security and build documentation complete.

---

## 16. Claude execution behavior

Proceed autonomously. Do not stop at an architecture proposal — create real files and working code. At every milestone: inspect the repo → state the goal in one paragraph → implement the smallest complete vertical slice → build from the terminal → run tests → fix → update docs → report **exact commands and real outcomes**.

Truthfulness rules (absolute):

* Never claim a build succeeded unless the command actually completed successfully.
* Never claim tests pass unless they were executed.
* Never claim the app launches unless it was packaged and opened.
* If a dependency or API is uncertain, research primary sources first: Apple docs, SwiftPM docs, CryptoKit docs, the official Argon2 reference, IETF RFCs, NIST publications. Never rely solely on tutorials or generated snippets.
* When a security tradeoff appears, write an ADR — document it, don't hide it. When a requested behavior would be insecure, implement the safest compatible interpretation and explain the residual limitation.
* When a design decision is ambiguous, resolve it *inside* the §3 system (tokens, components, principles) and record it in `docs/design-system.md` — never with a one-off style.

### Immediate first task

Execute M0 + M1: repository structure, `Package.swift`, token-styled SwiftUI shell, packaging scripts, crypto module interfaces, SecureRandom, SecureBytes, Argon2id integration plan, AES-GCM wrapper, HKDF hierarchy, initial tests, README, SECURITY, and the docs skeleton (architecture, threat-model, cryptography, design-system, build-without-xcode). Then run `swift build`, `swift test`, `./scripts/package-app.sh`.

First functional demonstration: create a temp test vault → accept a test password via secure prompt or dev UI → derive PKEK (Argon2id) → generate + wrap a random VMK → save the authenticated header → reopen → reject a wrong password → detect a modified tag → build and launch the SwiftUI app without Xcode. **Do not store real vault items until crypto and tamper tests pass.**

---

## 17. Final architectural picture

```
Master password ──Argon2id(per-vault salt)──▶ PKEK
PKEK ──authenticated unwrap──▶ VMK (random, 256-bit)
VMK ──HKDF-SHA256, domain-separated──▶ record / attachment / manifest /
                                       backup / search-session subkeys
subkeys ──wrap──▶ per-record & per-attachment random DEKs
DEKs ──AES-256-GCM + AAD──▶ authenticated encrypted local data
```

The master password (plus an optional, user-held recovery key) is the only persistent root of trust. No Keychain, no server, no account. Entirely local, entirely terminal-buildable, transparent about its limits, structured for independent review — and beautiful enough that using it every day feels like a pleasure, not a chore.
