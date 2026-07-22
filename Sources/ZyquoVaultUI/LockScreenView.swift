import AppKit
import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultDesign
import ZyquoVaultStorage

/// The lock screen (§3.4): centered radius.xl card on canvas, secure field,
/// full-width unlock button that morphs into a KDF progress capsule, inline
/// Caps Lock caution, calm ambiguous error copy, quiet recovery link.
struct LockScreenView: View {
    let model: AppModel

    @State private var password = ""
    @State private var deriving = false
    @State private var errorMessage: String?
    @State private var capsLockOn = false
    @State private var showRecovery = false
    @State private var eventMonitor: Any?

    var body: some View {
        ZStack {
            Zyquo.color.canvas.ignoresSafeArea()

            ZyquoCard(
                cornerRadius: Zyquo.radius.xl,
                elevation: Zyquo.elevation.level3,
                padding: Zyquo.spacing.xxl
            ) {
                VStack(spacing: Zyquo.spacing.l) {
                    appMark
                    Text(model.vaultName)
                        .font(Zyquo.type.display)
                        .foregroundStyle(Zyquo.color.inkPrimary)
                    Text("Locked")
                        .font(Zyquo.type.callout)
                        .foregroundStyle(Zyquo.color.inkSecondary)

                    if showRecovery {
                        RecoveryUnlockView(model: model, back: { showRecovery = false })
                    } else {
                        passwordForm
                    }
                }
                .frame(width: 356)
            }
        }
        .onAppear(perform: installCapsLockMonitor)
        .onDisappear(perform: removeCapsLockMonitor)
    }

    private var passwordForm: some View {
        VStack(spacing: Zyquo.spacing.s) {
            ZyquoSecureField("Master password", text: $password, onSubmit: unlock)
                .disabled(deriving)
                .accessibilityLabel("Master password")

            if capsLockOn {
                Label("Caps Lock is on", systemImage: "capslock")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.caution)
            }

            if deriving {
                HStack(spacing: Zyquo.spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Deriving keys…")
                        .font(Zyquo.type.headline)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Zyquo.spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                        .fill(Zyquo.color.surfaceSunken)
                )
            } else {
                ZyquoButton("Unlock", fullWidth: true, action: unlock)
                    .keyboardShortcut(.defaultAction)
            }

            if let errorMessage {
                ZyquoBanner(.critical, errorMessage)
            }

            ZyquoButton("I forgot my password…", role: .quiet) {
                errorMessage = nil
                showRecovery = true
            }
        }
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

    private func unlock() {
        guard !password.isEmpty, !deriving, let directory = model.vaultDirectory else { return }
        deriving = true
        errorMessage = nil
        let secret = SecureBytes(utf8: password)
        Task {
            defer { deriving = false }
            do {
                try await model.session.unlock(directory: directory, password: secret)
                password = ""
                model.didUnlock()
            } catch VaultSession.SessionError.tooManyAttempts(let seconds) {
                errorMessage = "Too many attempts. Try again in \(seconds) s."
            } catch StorageError.fileLocked(let pid) {
                errorMessage = "The vault is open in another process\(pid.map { " (\($0))" } ?? "")."
            } catch {
                errorMessage = "The password is incorrect or the vault file is damaged. Try again, or open Recovery."
            }
            secret.wipe()
        }
    }

    // MARK: Caps Lock

    private func installCapsLockMonitor() {
        capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            capsLockOn = event.modifierFlags.contains(.capsLock)
            return event
        }
    }

    private func removeCapsLockMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// Recovery-key unlock (§7.1): honest copy, same ambiguous failure text.
struct RecoveryUnlockView: View {
    let model: AppModel
    let back: () -> Void

    @State private var keyInput = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Zyquo.spacing.s) {
            ZyquoBanner(.ceremony, "Enter the recovery key you saved when this vault was created (ZQRK-…). Without the password or this key, the vault cannot be opened by anyone — including Zyquo.")

            ZyquoSecureField("Recovery key", text: $keyInput, onSubmit: unlock)
                .disabled(working)

            if working {
                ProgressView().controlSize(.small)
            } else {
                ZyquoButton("Unlock with recovery key", fullWidth: true, action: unlock)
            }
            if let errorMessage {
                ZyquoBanner(.critical, errorMessage)
            }
            ZyquoButton("Back", role: .quiet, action: back)
        }
    }

    private func unlock() {
        guard !keyInput.isEmpty, !working, let directory = model.vaultDirectory else { return }
        working = true
        errorMessage = nil
        Task {
            defer { working = false }
            do {
                let key = try RecoveryKey.parse(keyInput)
                try await model.session.unlock(directory: directory, recoveryKey: key)
                key.bytes.wipe()
                keyInput = ""
                model.didUnlock()
            } catch VaultSession.SessionError.tooManyAttempts(let seconds) {
                errorMessage = "Too many attempts. Try again in \(seconds) s."
            } catch {
                errorMessage = "That recovery key does not open this vault, or the vault file is damaged."
            }
        }
    }
}
