import SwiftUI

/// Tag pill (§3.3): accentSoft fill, radius.full via capsule.
public struct ZyquoTag: View {
    private let text: String
    private let onRemove: (() -> Void)?

    public init(_ text: String, onRemove: (() -> Void)? = nil) {
        self.text = text
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: Zyquo.spacing.xxs) {
            Text(text)
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.accent)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Zyquo.color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(text)")
            }
        }
        .padding(.vertical, Zyquo.spacing.xxs)
        .padding(.horizontal, Zyquo.spacing.xs)
        .background(Capsule(style: .continuous).fill(Zyquo.color.accentSoft))
    }
}

/// Item row (§3.3): leading rounded type-icon tile, title, subtitle, trailing
/// metadata; selection is an accentSoft fill with radius.m, never full-bleed.
public struct ZyquoListRow: View {
    private let icon: String
    private let title: String
    private let subtitle: String?
    private let trailing: String?
    private let isFavorite: Bool
    private let selected: Bool

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        trailing: String? = nil,
        isFavorite: Bool = false,
        selected: Bool = false
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.isFavorite = isFavorite
        self.selected = selected
    }

    public var body: some View {
        HStack(spacing: Zyquo.spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: Zyquo.radius.xs, style: .continuous)
                    .fill(Zyquo.color.accentSoft)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Zyquo.color.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(Zyquo.type.body)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Zyquo.spacing.xs)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Zyquo.color.sealGold)
                    .accessibilityLabel("Favorite")
            }
            if let trailing {
                Text(trailing)
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkTertiary)
            }
        }
        .padding(.vertical, Zyquo.spacing.xs)
        .padding(.horizontal, Zyquo.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Zyquo.radius.m, style: .continuous)
                .fill(selected ? Zyquo.color.accentSoft : .clear)
        )
        .contentShape(Rectangle())
    }
}

/// Empty state (§3.3): an invitation, never a dead end.
public struct ZyquoEmptyState: View {
    private let icon: String
    private let message: String
    private let actionTitle: String?
    private let action: () -> Void

    public init(icon: String, message: String, actionTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.icon = icon
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Zyquo.spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Zyquo.color.inkTertiary)
            Text(message)
                .font(Zyquo.type.callout)
                .foregroundStyle(Zyquo.color.inkSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle {
                ZyquoButton(actionTitle, role: .secondary, action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Zyquo.spacing.xl)
    }
}
