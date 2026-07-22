import SwiftUI

/// Zyquo button roles (§3.3). All radius.s, continuous corners, with pressed /
/// hover states. `destructive` is reserved for genuinely destructive actions and
/// is confirm-gated at the call site.
public enum ZyquoButtonRole: Sendable {
    case primary
    case secondary
    case destructive
    case quiet
}

public struct ZyquoButton: View {
    private let title: String
    private let role: ZyquoButtonRole
    private let fullWidth: Bool
    private let action: () -> Void
    @State private var hovering = false

    public init(
        _ title: String,
        role: ZyquoButtonRole = .primary,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Zyquo.type.headline)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, Zyquo.spacing.xs)
                .padding(.horizontal, Zyquo.spacing.m)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                        .fill(fillColor.opacity(hovering ? 0.9 : 1))
                )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Zyquo.motion.hover) { hovering = inside }
        }
    }

    private var fillColor: Color {
        switch role {
        case .primary: Zyquo.color.accent
        case .secondary: Zyquo.color.surfaceSunken
        case .destructive: Zyquo.color.critical
        case .quiet: .clear
        }
    }

    private var labelColor: Color {
        switch role {
        case .primary, .destructive: Zyquo.color.surface
        case .secondary: Zyquo.color.inkPrimary
        case .quiet: Zyquo.color.accent
        }
    }
}
