# Zyquo Vault — Design system ("Zyquo Soft Light")

The normative source is CLAUDE.md §3; this file records the implemented tokens, decisions, and per-milestone review notes. Everything visual comes from `Sources/ZyquoVaultDesign/` — `scripts/audit-design-tokens.sh` fails CI if UI code carries raw hex, literal radii, or ad-hoc shadows.

## Decisions log

- **Zyquo Blue refined: `#3D6BFF` → `#3563F5`.** The spec's reference accent gives 4.43:1 against white button labels — just under WCAG AA 4.5:1, and §3.2 makes AA a MUST while the hex is explicitly a reference "to refine". `#3563F5` yields ≈ 4.9:1 on white labels and ≈ 4.9:1 on surface, keeping the same vivid character. Enforced by `ContrastTests`.
- **App icon (vault edition):** the Zyquo squircle and blue gradient are kept for brand continuity; the Z is set in warm orange (`#FFB84D → #F07300`) and a white padlock with an ink-blue keyhole marks the app as the vault. Source: `Resources/AppIcon.svg`, rasterized with cairosvg → `iconutil`.
- **Elevation shadows** are implemented as `zyquoShadow(_:)` taking the token levels 1–3; SwiftUI's `radius` receives `blur/2` to approximate the CSS-style blur values in the spec.
- **Concentric radii** via `Zyquo.radius.nested(in:inset:)` = outer − inset, floored at `radius.xs` (tested).

## Implemented tokens (M0)

Colors (light reference): `canvas #F7F6F3`, `surface #FFFFFF`, `surfaceSunken #EFEEEA`, `inkPrimary #1C1B1A`, `inkSecondary #6E6B66`, `inkTertiary #A5A29C`, `accent #3563F5`, `accentSoft` (accent @ 11%), `positive #2E9E6B`, `caution #C98A2B`, `critical #C94F3D`, `sealGold #B9975B`, `hairline` (ink @ 8%).

Radii: 6 / 10 / 14 / 20 / 28 / ∞, all `.continuous`. Spacing: 4-pt grid (4…56). Type: SF Pro Rounded (display/titles), SF Pro (body), SF Mono medium (secrets). Elevation: (y2 blur8 6%), (y4 blur16 8%), (y12 blur32 12%). Motion: spring(0.35, 0.85), 180 ms ease-out hovers.

## Components

- `ZyquoCard` — signature surface (M0).
- `ZyquoButton` — primary / secondary / destructive / quiet with hover states; labels never wrap (M0, fixed at the M4 gate).
- `ZyquoSecureField` — input well with reveal toggle and accent focus ring (M3).
- `ZyquoStrengthMeter` — segmented, "estimate"-labeled (M3).
- `ZyquoBanner` — info / warning / critical / ceremony (sealGold) inline banners (M3).
- `ZyquoSecretField` — read-only secret row: mono, concealed dots, one-reveal-at-a-time via a shared binding, copy with transient "Copied ✓"; concealed values are never exposed to accessibility (M4).
- `ZyquoTag` — accentSoft pill, optional remove affordance (M4).
- `ZyquoListRow` — icon tile + title/subtitle + trailing metadata; selection is an accentSoft radius.m pill (M4).
- `ZyquoEmptyState` — icon + one line + one action; every empty screen is an invitation (M4).

- `ZyquoTOTPRing` — circular countdown, accent stroke, `caution` under 5 s; static under Reduce Motion (M5).
- `ClipboardChip` (UI layer) — "Clears in 27 s" capsule after copying a secret (M5).

## Review gates

- **M0 gate (2026-07-22):** contrast suite green; no raw values in UI target; single accent; continuous corners only; the one decoration removed in self-critique was a second gradient on the shell card (now flat `surface`).
- **M3/M4 gate (2026-07-22):** run against the live app (screenshots in `docs/screenshots/`: `m3-lock-screen.png`, `m4-main-window.png`, `m4-item-detail.png`, `m4-item-editor.png`). Checked: radii concentricity on nested wells, AA contrast (automated), empty/error/loading states present on lock, list, detail, editor; one secret revealed at a time verified. Defect found and fixed: header action button labels wrapped at narrow detail widths (`ZyquoButton` now refuses to wrap). Auto-lock observed working live during the review session.
- **M5 gate (2026-07-22):** live-app review of the TOTP card (`m5-totp-detail.png`: grouped mono code, ring, copy) and Markdown notes (`m5-markdown-note.png`: headings, bold, checklists — hostile input covered by tests, no HTML path exists). Generator popover reviewed for token compliance; entropy always labeled "estimate".
- **M8 gate (2026-07-23, final):** dark mode derived from the SAME token names via dynamic colors, verified live (`m8-lock-screen-dark.png`); both palettes pass automated WCAG AA. Self-critique findings fixed: elevation shadows were ink-tinted, which would have inverted to *white* shadows in dark mode — replaced with a dedicated always-dark `shadow` token; `accentSoft` nudged 11% → 13% so selections stay visible on dark surfaces.

## Dark palette (§3.6 — same token names)

`canvas #161514`, `surface #1E1D1B`, `surfaceSunken #141312`, `inkPrimary #ECEAE6`, `inkSecondary #A5A29C`, `inkTertiary #6E6B62`, `accent #3D63E8` (slightly deeper so white labels keep AA 4.5:1), `positive #3FB57E`, `caution #D89A44`, `critical #D96A57`, `sealGold #CBA96B`. Appearance setting: System / Light / Dark, **default Light**.
