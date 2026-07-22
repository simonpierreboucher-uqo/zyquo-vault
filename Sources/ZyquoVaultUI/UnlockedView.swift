import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultDesign
import ZyquoVaultDomain
import ZyquoVaultStorage

/// Vault settings sheet (M3 maintenance, reachable from the main window):
/// integrity verification, master-password change, recovery-key rotation.
struct VaultSettingsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var hasRecoveryKey = false
    @State private var integritySummary: String?
    @State private var showChangePassword = false
    @State private var rotatedKeyDisplay: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Zyquo.spacing.l) {
            HStack {
                Text("Vault settings")
                    .font(Zyquo.type.title)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                Spacer()
                ZyquoButton("Done", role: .secondary) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
                VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                    Text("Security")
                        .font(Zyquo.type.headline)
                        .foregroundStyle(Zyquo.color.inkPrimary)
                    HStack(spacing: Zyquo.spacing.s) {
                        ZyquoButton("Change master password…", role: .secondary) {
                            showChangePassword = true
                        }
                        ZyquoButton(hasRecoveryKey ? "Rotate recovery key…" : "Create recovery key…", role: .secondary) {
                            rotateRecoveryKey()
                        }
                    }
                    ZyquoButton("Verify vault integrity", role: .secondary, action: runIntegrityCheck)
                    if let integritySummary {
                        ZyquoBanner(integritySummary.hasPrefix("OK") ? .info : .critical, integritySummary)
                    }
                    if let errorMessage {
                        ZyquoBanner(.critical, errorMessage)
                    }
                }
            }

            if !model.startupWarnings.isEmpty {
                ForEach(model.startupWarnings, id: \.self) { warning in
                    ZyquoBanner(.warning, warning)
                }
            }
        }
        .padding(Zyquo.spacing.xl)
        .frame(width: 480)
        .background(Zyquo.color.canvas)
        .task {
            hasRecoveryKey = await model.session.hasRecoveryKey
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet(model: model)
        }
        .sheet(isPresented: Binding(
            get: { rotatedKeyDisplay != nil },
            set: { if !$0 { rotatedKeyDisplay = nil } }
        )) {
            rotatedKeySheet
        }
    }

    private var rotatedKeySheet: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.xl, elevation: Zyquo.elevation.level3, padding: Zyquo.spacing.xxl) {
            VStack(spacing: Zyquo.spacing.m) {
                Text("Your new recovery key")
                    .font(Zyquo.type.title)
                    .foregroundStyle(Zyquo.color.sealGold)
                Text(rotatedKeyDisplay ?? "")
                    .font(Zyquo.type.mono)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                ZyquoBanner(.ceremony, "The previous recovery key no longer works. This one is shown once — write it down or print it now.")
                ZyquoButton("Done", fullWidth: true) { rotatedKeyDisplay = nil }
            }
            .frame(width: 420)
        }
        .padding(Zyquo.spacing.l)
    }

    private func runIntegrityCheck() {
        integritySummary = nil
        Task {
            do {
                let report = try await model.session.verifyIntegrity(deep: true)
                integritySummary = report.isClean
                    ? "OK — \(report.recordCount) record(s), every ciphertext authenticated."
                    : "Problems found: \(report.missingRecords.count) missing, \(report.corruptedRecords.count) corrupted, \(report.unexpectedFiles.count) unexpected."
            } catch {
                integritySummary = "Verification could not run (vault locked?)."
            }
        }
    }

    private func rotateRecoveryKey() {
        errorMessage = nil
        Task {
            do {
                let key = try await model.session.rotateRecoveryKey()
                rotatedKeyDisplay = key.displayString()
                key.bytes.wipe()
                hasRecoveryKey = true
            } catch {
                errorMessage = "The recovery key could not be rotated."
            }
        }
    }
}

/// §5.4 password change: current password re-verified, then re-wrap + verify.
struct ChangePasswordSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.xl, elevation: Zyquo.elevation.level3, padding: Zyquo.spacing.xxl) {
            VStack(spacing: Zyquo.spacing.m) {
                Text("Change master password")
                    .font(Zyquo.type.title)
                    .foregroundStyle(Zyquo.color.inkPrimary)

                field("Current password", text: $current)
                VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                    field("New password", text: $newPassword)
                    ZyquoStrengthMeter(entropyBits: PasswordStrength.estimateEntropyBits(newPassword))
                }
                field("Confirm new password", text: $confirmation)

                ZyquoBanner(.info, "Your data is not re-encrypted — the vault key is re-protected under the new password. The recovery key, if any, keeps working.")

                if let errorMessage {
                    ZyquoBanner(.critical, errorMessage)
                }

                if working {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: Zyquo.spacing.s) {
                        ZyquoButton("Cancel", role: .quiet) { dismiss() }
                        ZyquoButton("Change password", fullWidth: true, action: change)
                    }
                }
            }
            .frame(width: 400)
        }
        .padding(Zyquo.spacing.l)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            Text(label)
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkSecondary)
            ZyquoSecureField(label, text: text)
        }
    }

    private func change() {
        guard !working else { return }
        guard !newPassword.isEmpty else { errorMessage = "A new password is required."; return }
        guard newPassword == confirmation else { errorMessage = "The new passwords do not match."; return }
        working = true
        errorMessage = nil
        let currentSecret = SecureBytes(utf8: current)
        let newSecret = SecureBytes(utf8: newPassword)
        Task {
            defer { working = false }
            guard await model.session.verifyPassword(currentSecret) else {
                currentSecret.wipe()
                newSecret.wipe()
                errorMessage = "The current password is incorrect."
                return
            }
            do {
                try await model.session.changePassword(to: newSecret)
                currentSecret.wipe()
                newSecret.wipe()
                dismiss()
            } catch {
                errorMessage = "The password could not be changed. The old password still works."
            }
        }
    }
}
