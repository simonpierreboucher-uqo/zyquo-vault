import SwiftUI

/// Secure input well (§3.3): surfaceSunken, radius.s, accent focus ring, optional
/// reveal toggle. The revealed state is never the default and resets when the
/// binding is cleared.
public struct ZyquoSecureField: View {
    private let title: String
    @Binding private var text: String
    private let allowReveal: Bool
    private let onSubmit: () -> Void
    @State private var revealed = false
    @FocusState private var focused: Bool

    public init(
        _ title: String,
        text: Binding<String>,
        allowReveal: Bool = true,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.title = title
        self._text = text
        self.allowReveal = allowReveal
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: Zyquo.spacing.xs) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Zyquo.type.mono)
            .foregroundStyle(Zyquo.color.inkPrimary)
            .focused($focused)
            .onSubmit(onSubmit)

            if allowReveal, !text.isEmpty {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(Zyquo.color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "Conceal" : "Reveal")
            }
        }
        .padding(.vertical, Zyquo.spacing.xs)
        .padding(.horizontal, Zyquo.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                .fill(Zyquo.color.surfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                .strokeBorder(Zyquo.color.accent.opacity(focused ? 0.4 : 0), lineWidth: 2)
        )
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty { revealed = false }
        }
    }
}
