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

## Components (M0)

- `ZyquoCard` — signature surface (used by the shell's status card).
- `ZyquoButton` — primary / secondary / destructive / quiet with hover states.

Remaining §3.3 components (secure fields, tags, strength meter, TOTP ring, banners, list rows, empty states) arrive with M3–M5, each added here with usage notes and screenshots.

## Review gates

- **M0 gate (run 2026-07-22):** contrast test suite green; no raw values in UI target (audit script green); single accent; continuous corners only; the one decoration removed in self-critique was a second gradient on the shell card (now flat `surface`).
- Dark mode: deliberately absent until light mode is complete (§3.6). Default appearance: Light.
