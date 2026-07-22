import SwiftUI

/// Segmented password-strength meter (§3.3). Colors run critical → caution →
/// positive; the label always says "estimate" — no absolute claims.
public struct ZyquoStrengthMeter: View {
    /// Entropy estimate in bits (computed by the domain layer).
    private let entropyBits: Double

    public init(entropyBits: Double) {
        self.entropyBits = entropyBits
    }

    private var level: Int {
        switch entropyBits {
        case ..<28: 0
        case ..<45: 1
        case ..<60: 2
        case ..<80: 3
        default: 4
        }
    }

    private var color: Color {
        switch level {
        case 0, 1: Zyquo.color.critical
        case 2: Zyquo.color.caution
        default: Zyquo.color.positive
        }
    }

    private var label: String {
        switch level {
        case 0: "Very weak"
        case 1: "Weak"
        case 2: "Fair"
        case 3: "Strong"
        default: "Very strong"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            HStack(spacing: Zyquo.spacing.xxs) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: Zyquo.radius.xs, style: .continuous)
                        .fill(index <= level && entropyBits > 0 ? color : Zyquo.color.hairline)
                        .frame(height: 6)
                }
            }
            Text("\(label) — ≈\(Int(entropyBits)) bits (estimate)")
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(label), approximately \(Int(entropyBits)) bits. Estimate.")
    }
}
