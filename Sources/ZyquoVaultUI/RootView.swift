import SwiftUI
import ZyquoVaultDesign

/// M0/M1 shell: the canvas + signature Vault Card, styled entirely from tokens.
/// The real lock screen (secure field, KDF progress, unlock flow) arrives with M3;
/// this view honestly reports the current milestone instead of simulating one.
public struct RootView: View {
    public init() {}

    public var body: some View {
        ZStack {
            Zyquo.color.canvas.ignoresSafeArea()

            ZyquoCard(
                cornerRadius: Zyquo.radius.xl,
                elevation: Zyquo.elevation.level3,
                padding: Zyquo.spacing.xxl
            ) {
                VStack(spacing: Zyquo.spacing.l) {
                    appMark
                    Text("Zyquo Vault")
                        .font(Zyquo.type.display)
                        .foregroundStyle(Zyquo.color.inkPrimary)
                    Text("Local-first encrypted vault for macOS")
                        .font(Zyquo.type.body)
                        .foregroundStyle(Zyquo.color.inkSecondary)

                    VStack(alignment: .leading, spacing: Zyquo.spacing.xs) {
                        milestoneRow(done: true, "Cryptographic core — Argon2id, HKDF, AES-256-GCM")
                        milestoneRow(done: true, "Authenticated vault header with tamper detection")
                        milestoneRow(done: true, "Crash-safe encrypted records, manifest and journal")
                        milestoneRow(done: false, "Vault creation and unlock (milestone M3)")
                        milestoneRow(done: false, "Items, search, generator (milestones M4–M5)")
                    }
                    .padding(Zyquo.spacing.m)
                    .background(
                        RoundedRectangle(
                            cornerRadius: Zyquo.radius.nested(in: Zyquo.radius.xl, inset: Zyquo.spacing.m),
                            style: .continuous
                        )
                        .fill(Zyquo.color.surfaceSunken)
                    )

                    Text("Under active development — not yet audited. Do not store irreplaceable production credentials.")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var appMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Zyquo.radius.m, style: .continuous)
                .fill(Zyquo.color.accentSoft)
                .frame(width: 64, height: 64)
            Image(systemName: "lock.shield")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Zyquo.color.accent)
        }
        .accessibilityHidden(true)
    }

    private func milestoneRow(done: Bool, _ label: String) -> some View {
        HStack(spacing: Zyquo.spacing.xs) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? Zyquo.color.positive : Zyquo.color.inkTertiary)
            Text(label)
                .font(Zyquo.type.callout)
                .foregroundStyle(done ? Zyquo.color.inkPrimary : Zyquo.color.inkSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(done ? "complete" : "planned")")
    }
}
