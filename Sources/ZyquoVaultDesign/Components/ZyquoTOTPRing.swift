import SwiftUI

/// Circular TOTP countdown (§3.3): accent stroke draining clockwise, turning
/// `caution` under 5 s. Purely presentational — the parent supplies progress.
public struct ZyquoTOTPRing: View {
    private let secondsRemaining: Int
    private let period: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(secondsRemaining: Int, period: Int) {
        self.secondsRemaining = secondsRemaining
        self.period = max(1, period)
    }

    private var fraction: CGFloat {
        CGFloat(secondsRemaining) / CGFloat(period)
    }

    private var color: Color {
        secondsRemaining <= 5 ? Zyquo.color.caution : Zyquo.color.accent
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Zyquo.color.hairline, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
            Text("\(secondsRemaining)")
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkSecondary)
                .monospacedDigit()
        }
        .frame(width: 32, height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code renews in \(secondsRemaining) seconds")
    }
}
