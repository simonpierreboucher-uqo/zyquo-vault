import SwiftUI

/// Inline banner (§3.3) — used instead of intrusive alerts wherever possible.
/// Soft tinted fill, radius.s, calm copy.
public struct ZyquoBanner: View {
    public enum Kind: Sendable {
        case info
        case warning
        case critical
        case ceremony // sealGold — recovery-key moments
    }

    private let kind: Kind
    private let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    private var tint: Color {
        switch kind {
        case .info: Zyquo.color.accent
        case .warning: Zyquo.color.caution
        case .critical: Zyquo.color.critical
        case .ceremony: Zyquo.color.sealGold
        }
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        case .ceremony: "key.horizontal"
        }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Zyquo.spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(Zyquo.type.callout)
                .foregroundStyle(Zyquo.color.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Zyquo.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                .fill(tint.opacity(0.1))
        )
        .accessibilityElement(children: .combine)
    }
}
