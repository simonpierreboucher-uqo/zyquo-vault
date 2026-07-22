import SwiftUI

/// Read-only secret display row (§3.3): mono face, concealed dots by default,
/// eye toggle (one reveal at a time via the shared `revealedField` binding),
/// copy button with a transient "Copied ✓" state.
///
/// Accessibility: the concealed value is NEVER exposed to assistive
/// technologies — the accessibility value stays "concealed" until revealed.
public struct ZyquoSecretField: View {
    private let id: UUID
    private let label: String
    private let value: String
    private let concealable: Bool
    private let copyable: Bool
    /// Shared across the detail view so only one secret is revealed at a time.
    @Binding private var revealedField: UUID?
    private let onCopy: () -> Void
    @State private var justCopied = false

    public init(
        id: UUID,
        label: String,
        value: String,
        concealable: Bool = true,
        copyable: Bool = true,
        revealedField: Binding<UUID?>,
        onCopy: @escaping () -> Void = {}
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.concealable = concealable
        self.copyable = copyable
        self._revealedField = revealedField
        self.onCopy = onCopy
    }

    private var revealed: Bool { !concealable || revealedField == id }

    public var body: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            Text(label)
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkSecondary)
            HStack(spacing: Zyquo.spacing.xs) {
                Text(revealed ? value : String(repeating: "•", count: min(max(value.count, 6), 14)))
                    .font(Zyquo.type.mono)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                    .kerning(revealed ? 0 : 1.5)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(label)
                    .accessibilityValue(revealed ? value : "concealed")

                if concealable {
                    Button {
                        withAnimation(Zyquo.motion.hover) {
                            revealedField = revealed ? nil : id
                        }
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .foregroundStyle(Zyquo.color.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "Conceal \(label)" : "Reveal \(label)")
                }

                if copyable {
                    Button {
                        onCopy()
                        withAnimation(Zyquo.motion.hover) { justCopied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(Zyquo.motion.hover) { justCopied = false }
                        }
                    } label: {
                        if justCopied {
                            Label("Copied", systemImage: "checkmark")
                                .font(Zyquo.type.caption)
                                .foregroundStyle(Zyquo.color.positive)
                        } else {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Zyquo.color.inkSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy \(label)")
                }
            }
            .padding(.vertical, Zyquo.spacing.xs)
            .padding(.horizontal, Zyquo.spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                    .fill(Zyquo.color.surfaceSunken)
            )
        }
    }
}
