import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultDesign
import ZyquoVaultDomain

/// Live one-time code (§10.5): grouped mono code, countdown ring, copy. The
/// seed stays encrypted at rest; generated codes are never stored or logged.
struct TOTPCodeCard: View {
    let seedField: VaultField
    let clipboard: ClipboardManager
    @State private var justCopied = false

    private var configuration: TOTPConfiguration? {
        guard let secret = try? Base32.decode(seedField.value.reveal()), !secret.isEmpty else { return nil }
        return TOTPConfiguration(secret: secret)
    }

    var body: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            if let configuration {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    codeRow(configuration: configuration, date: context.date)
                }
            } else {
                ZyquoBanner(.warning, "The one-time code secret is not valid base32. Edit the item to fix it.")
            }
        }
    }

    @ViewBuilder
    private func codeRow(configuration: TOTPConfiguration, date: Date) -> some View {
        if let result = try? TOTPGenerator.code(for: configuration, at: date) {
            HStack(spacing: Zyquo.spacing.m) {
                VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                    Text("One-time code")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                    Text(TOTPGenerator.grouped(result.code))
                        .font(Zyquo.type.monoLarge)
                        .foregroundStyle(Zyquo.color.inkPrimary)
                        .monospacedDigit()
                        .accessibilityLabel("One-time code \(result.code)")
                }
                Spacer()
                ZyquoTOTPRing(secondsRemaining: result.secondsRemaining, period: configuration.period)
                Button {
                    clipboard.copySecret(result.code)
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
                .accessibilityLabel("Copy one-time code")
            }
        } else {
            ZyquoBanner(.warning, "The one-time code could not be generated from this secret.")
        }
    }
}
