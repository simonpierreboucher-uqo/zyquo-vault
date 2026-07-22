import Foundation
import Testing
@testable import ZyquoVaultDesign

/// Automated WCAG AA contrast checks over the token palette (CLAUDE.md §3.2).
@Suite("Design token contrast (WCAG AA)")
struct ContrastTests {

    /// WCAG 2.x relative luminance from an sRGB hex value.
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func allDeclaredPairsMeetTheirMinimum() {
        for pair in Zyquo.color.contrastPairs {
            let ratio = Self.contrastRatio(pair.foreground, pair.background)
            #expect(
                ratio >= pair.minimumRatio,
                "\(pair.name): ratio \(ratio) below required \(pair.minimumRatio)"
            )
        }
    }

    @Test func radiiAreConcentricAndOrdered() {
        #expect(Zyquo.radius.xs < Zyquo.radius.s)
        #expect(Zyquo.radius.s < Zyquo.radius.m)
        #expect(Zyquo.radius.m < Zyquo.radius.l)
        #expect(Zyquo.radius.l < Zyquo.radius.xl)
        // Nested radius = outer − inset, floored at xs.
        #expect(Zyquo.radius.nested(in: Zyquo.radius.xl, inset: 8) == Zyquo.radius.xl - 8)
        #expect(Zyquo.radius.nested(in: Zyquo.radius.s, inset: 8) == Zyquo.radius.xs)
    }
}
