import SwiftUI

/// "Zyquo Soft Light" design tokens (CLAUDE.md §3). Every color, radius, spacing,
/// font, and shadow in the UI comes from here — UI code never carries raw values.
/// Light theme is the reference; dark values will be derived from the same names
/// after light mode is complete (§3.6).
public enum Zyquo {

    // MARK: Color

    public enum color {
        /// App background — warm off-white, never pure white.
        public static let canvas = rgb(0xF7F6F3)
        /// Cards, panels, sheets.
        public static let surface = rgb(0xFFFFFF)
        /// Wells, input backgrounds, code/secret fields.
        public static let surfaceSunken = rgb(0xEFEEEA)
        /// Primary text — near-black, warm.
        public static let inkPrimary = rgb(0x1C1B1A)
        /// Secondary text, labels.
        public static let inkSecondary = rgb(0x6E6B66)
        /// Placeholders, disabled, metadata.
        public static let inkTertiary = rgb(0xA5A29C)
        /// Zyquo Blue — primary actions, selection, focus. Refined from the spec's
        /// #3D6BFF reference so white button labels meet WCAG AA 4.5:1 (§3.2 rule
        /// beats the reference value; see docs/design-system.md).
        public static let accent = rgb(0x3563F5)
        /// Selected rows, chips, hover fills.
        public static let accentSoft = accent.opacity(0.11)
        /// Success, "copied", strong passwords.
        public static let positive = rgb(0x2E9E6B)
        /// Warnings, aging passwords.
        public static let caution = rgb(0xC98A2B)
        /// Destructive actions, integrity failures — muted, not fire-alarm red.
        public static let critical = rgb(0xC94F3D)
        /// Reserved: favorites star, recovery-key ceremony accents.
        public static let sealGold = rgb(0xB9975B)
        /// Separators — used sparingly; whitespace is the primary grouping tool.
        public static let hairline = inkPrimary.opacity(0.08)

        /// Raw sRGB components, exposed for the automated contrast tests.
        public static let contrastPairs: [(name: String, foreground: UInt32, background: UInt32, minimumRatio: Double)] = [
            ("inkPrimary on canvas", 0x1C1B1A, 0xF7F6F3, 4.5),
            ("inkPrimary on surface", 0x1C1B1A, 0xFFFFFF, 4.5),
            ("inkSecondary on canvas", 0x6E6B66, 0xF7F6F3, 4.5),
            ("inkSecondary on surface", 0x6E6B66, 0xFFFFFF, 4.5),
            ("accent on surface (large/icon)", 0x3563F5, 0xFFFFFF, 3.0),
            ("white on accent", 0xFFFFFF, 0x3563F5, 4.5),
            ("inkPrimary on surfaceSunken", 0x1C1B1A, 0xEFEEEA, 4.5),
        ]

        static func rgb(_ hex: UInt32) -> Color {
            Color(
                .sRGB,
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                opacity: 1
            )
        }
    }

    // MARK: Corner radius — continuous curves everywhere (§3.2)

    public enum radius {
        /// Tags, badges, small chips.
        public static let xs: CGFloat = 6
        /// Buttons, inputs, list rows.
        public static let s: CGFloat = 10
        /// Cards, item rows, sidebar selection.
        public static let m: CGFloat = 14
        /// Panels, detail cards, sheets.
        public static let l: CGFloat = 20
        /// Lock screen card, onboarding cards, modals.
        public static let xl: CGFloat = 28

        /// Concentric nesting: inner radius = outer radius − inset padding,
        /// floored at `xs` so tiny nested elements stay visibly rounded.
        public static func nested(in outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(xs, outer - inset)
        }
    }

    // MARK: Spacing — 4-pt grid (§3.2)

    public enum spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 40
        public static let huge: CGFloat = 56
    }

    // MARK: Typography (§3.2)

    public enum type {
        /// Display / vault name / lock screen — rounded face, titles only.
        public static let display = Font.system(size: 28, weight: .semibold, design: .rounded)
        public static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        public static let headline = Font.system(.headline)
        public static let body = Font.system(.body)
        public static let callout = Font.system(.callout)
        /// Secrets, keys, TOTP, passwords — slashed zero, tabular digits.
        public static let mono = Font.system(size: 14, weight: .medium, design: .monospaced)
        public static let monoLarge = Font.system(size: 24, weight: .medium, design: .monospaced)
        /// Metadata / captions.
        public static let caption = Font.system(size: 11)
    }

    // MARK: Elevation — soft, diffuse, never harsh (§3.2)

    public struct Elevation: Sendable {
        public let y: CGFloat
        public let blur: CGFloat
        public let opacity: Double
    }

    public enum elevation {
        /// Cards at rest.
        public static let level1 = Elevation(y: 2, blur: 8, opacity: 0.06)
        /// Hovered cards, popovers.
        public static let level2 = Elevation(y: 4, blur: 16, opacity: 0.08)
        /// Sheets, lock card, modals.
        public static let level3 = Elevation(y: 12, blur: 32, opacity: 0.12)
    }

    // MARK: Motion (§3.2)

    public enum motion {
        /// Standard spring for state changes.
        public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// Hovers.
        public static let hover = Animation.easeOut(duration: 0.18)
    }
}

extension View {
    /// Applies a Zyquo elevation shadow (ink-tinted, soft and diffuse).
    public func zyquoShadow(_ level: Zyquo.Elevation) -> some View {
        shadow(
            color: Zyquo.color.inkPrimary.opacity(level.opacity),
            radius: level.blur / 2, x: 0, y: level.y
        )
    }
}
