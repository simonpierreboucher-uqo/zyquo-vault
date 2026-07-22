import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultDesign
import ZyquoVaultDomain
import ZyquoVaultStorage

/// Welcome screen (first launch, no vault): local-first explanation + honest
/// development warning, then the creation flow (§10.1).
struct WelcomeView: View {
    let model: AppModel
    @State private var creating = false

    var body: some View {
        ZStack {
            Zyquo.color.canvas.ignoresSafeArea()
            if creating {
                CreateVaultView(model: model, cancel: { creating = false })
            } else {
                ZyquoCard(
                    cornerRadius: Zyquo.radius.xl,
                    elevation: Zyquo.elevation.level3,
                    padding: Zyquo.spacing.xxl
                ) {
                    VStack(spacing: Zyquo.spacing.l) {
                        Text("Welcome to Zyquo Vault")
                            .font(Zyquo.type.display)
                            .foregroundStyle(Zyquo.color.inkPrimary)
                        VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                            bullet("lock.shield", "Everything stays on this Mac. No account, no cloud, no telemetry — the vault works fully offline, forever.")
                            bullet("key", "Your master password is the only key. It is never stored anywhere, and Zyquo cannot recover it for you.")
                            bullet("wrench.and.screwdriver", "Zyquo Vault is under active development and not yet independently audited. Keep copies of irreplaceable credentials elsewhere for now.")
                        }
                        ZyquoButton("Create a vault", fullWidth: true) { creating = true }
                    }
                    .frame(width: 400)
                }
            }
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Zyquo.spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(Zyquo.color.accent)
                .frame(width: 20)
            Text(text)
                .font(Zyquo.type.callout)
                .foregroundStyle(Zyquo.color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Vault creation (§10.1): one decision per card — details → unrecoverability &
/// recovery-key opt-in → ceremony (sealGold) → calibrated creation.
struct CreateVaultView: View {
    enum Step: Equatable {
        case details
        case recoveryChoice
        case ceremony
        case creating(String)
    }

    let model: AppModel
    let cancel: () -> Void

    @State private var step: Step = .details
    @State private var name = "My vault"
    @State private var password = ""
    @State private var confirmation = ""
    @State private var wantsRecoveryKey = true
    @State private var recoveryKey: RecoveryKey?
    @State private var recoveryDisplay: String = ""
    @State private var ceremonyConfirmation = ""
    @State private var errorMessage: String?

    private var entropy: Double { PasswordStrength.estimateEntropyBits(password) }

    var body: some View {
        ZyquoCard(
            cornerRadius: Zyquo.radius.xl,
            elevation: Zyquo.elevation.level3,
            padding: Zyquo.spacing.xxl
        ) {
            Group {
                switch step {
                case .details: detailsStep
                case .recoveryChoice: recoveryChoiceStep
                case .ceremony: ceremonyStep
                case .creating(let stage): creatingStep(stage)
                }
            }
            .frame(width: 400)
        }
        .animation(Zyquo.motion.spring, value: step)
    }

    // MARK: Step 1 — name & master password

    private var detailsStep: some View {
        VStack(spacing: Zyquo.spacing.m) {
            Text("Create your vault")
                .font(Zyquo.type.title)
                .foregroundStyle(Zyquo.color.inkPrimary)

            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                Text("Vault name")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                TextField("My vault", text: $name)
                    .textFieldStyle(.plain)
                    .font(Zyquo.type.body)
                    .padding(.vertical, Zyquo.spacing.xs)
                    .padding(.horizontal, Zyquo.spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                            .fill(Zyquo.color.surfaceSunken)
                    )
            }

            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                Text("Master password")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                ZyquoSecureField("Master password", text: $password)
                ZyquoStrengthMeter(entropyBits: entropy)
                Text("Length beats complexity: a long phrase you can remember is stronger than a short jumble.")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkTertiary)
            }

            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                Text("Confirm password")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                ZyquoSecureField("Confirm password", text: $confirmation)
                if !confirmation.isEmpty && confirmation != password {
                    Text("The passwords do not match yet.")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.caution)
                }
            }

            if let errorMessage {
                ZyquoBanner(.critical, errorMessage)
            }

            ZyquoButton("Continue", fullWidth: true) {
                guard !password.isEmpty else { errorMessage = "A master password is required."; return }
                guard password == confirmation else { errorMessage = "The passwords do not match."; return }
                errorMessage = nil
                step = .recoveryChoice
            }
            ZyquoButton("Cancel", role: .quiet, action: cancel)
        }
    }

    // MARK: Step 2 — unrecoverability & opt-in

    private var recoveryChoiceStep: some View {
        VStack(spacing: Zyquo.spacing.m) {
            Text("If you forget your password")
                .font(Zyquo.type.title)
                .foregroundStyle(Zyquo.color.inkPrimary)
            ZyquoBanner(.warning, "There is no server and no account. If you forget the master password, the vault cannot be opened by anyone — including Zyquo. There are no security questions and no email reset.")
            Toggle(isOn: $wantsRecoveryKey) {
                VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                    Text("Create a recovery key")
                        .font(Zyquo.type.headline)
                        .foregroundStyle(Zyquo.color.inkPrimary)
                    Text("A one-time key you print or write down. Anyone holding it together with the vault file gets full access — store it like cash.")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Zyquo.color.accent)

            ZyquoButton(wantsRecoveryKey ? "Continue" : "Create without recovery key", fullWidth: true) {
                if wantsRecoveryKey {
                    do {
                        let key = try RecoveryKey.generate()
                        recoveryKey = key
                        recoveryDisplay = key.displayString()
                        step = .ceremony
                    } catch {
                        errorMessage = "Could not generate a recovery key."
                    }
                } else {
                    create()
                }
            }
            ZyquoButton("Back", role: .quiet) { step = .details }
        }
    }

    // MARK: Step 3 — recovery-key ceremony (sealGold moment)

    private var ceremonyStep: some View {
        VStack(spacing: Zyquo.spacing.m) {
            Text("Your recovery key")
                .font(Zyquo.type.title)
                .foregroundStyle(Zyquo.color.sealGold)
            Text(recoveryDisplay)
                .font(Zyquo.type.mono)
                .foregroundStyle(Zyquo.color.inkPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(Zyquo.spacing.m)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(
                        cornerRadius: Zyquo.radius.nested(in: Zyquo.radius.xl, inset: Zyquo.spacing.m),
                        style: .continuous
                    )
                    .fill(Zyquo.color.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: Zyquo.radius.nested(in: Zyquo.radius.xl, inset: Zyquo.spacing.m),
                        style: .continuous
                    )
                    .strokeBorder(Zyquo.color.sealGold.opacity(0.5), lineWidth: 1)
                )
            ZyquoBanner(.ceremony, "This key is shown once. Write it down or print it now — Zyquo keeps no copy, and it will not be shown again.")

            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                Text("Type the last group of the key to confirm you saved it")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                ZyquoSecureField("Last 4 characters", text: $ceremonyConfirmation, allowReveal: true)
            }
            if let errorMessage {
                ZyquoBanner(.critical, errorMessage)
            }

            ZyquoButton("I saved my recovery key — create the vault", fullWidth: true) {
                let lastGroup = recoveryDisplay.split(separator: "-").last.map(String.init) ?? ""
                guard ceremonyConfirmation.trimmingCharacters(in: .whitespaces).uppercased() == lastGroup else {
                    errorMessage = "That is not the last group of the key. Check what you wrote down."
                    return
                }
                errorMessage = nil
                create()
            }
            ZyquoButton("Back", role: .quiet) { step = .recoveryChoice }
        }
    }

    // MARK: Step 4 — calibration & creation

    private func creatingStep(_ stage: String) -> some View {
        VStack(spacing: Zyquo.spacing.m) {
            ProgressView().controlSize(.large)
            Text(stage)
                .font(Zyquo.type.headline)
                .foregroundStyle(Zyquo.color.inkSecondary)
            Text("The security level is calibrated to this Mac so unlocking takes about a second.")
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 160)
    }

    private func create() {
        step = .creating("Calibrating security level…")
        let secret = SecureBytes(utf8: password)
        let key = recoveryKey
        let chosenName = name.isEmpty ? "My vault" : name
        Task {
            do {
                let parameters = try await Task.detached(priority: .userInitiated) {
                    try Argon2id.calibrate()
                }.value
                step = .creating("Creating and verifying the vault…")
                let directory = AppModel.vaultsRoot().appendingPathComponent(UUID().uuidString)
                if let key {
                    _ = try await model.session.createVault(
                        at: directory, password: secret,
                        generateRecoveryKey: false, parameters: parameters
                    )
                    // Install the ceremony key the user already confirmed.
                    _ = try await installRecoveryKey(key)
                } else {
                    try await model.session.createVault(
                        at: directory, password: secret,
                        generateRecoveryKey: false, parameters: parameters
                    )
                }
                secret.wipe()
                password = ""
                confirmation = ""
                recoveryDisplay = ""
                ceremonyConfirmation = ""
                model.didCreateVault(at: directory, name: chosenName)
            } catch {
                secret.wipe()
                errorMessage = "Vault creation failed. Nothing was stored. (\(String(describing: error)))"
                step = .details
            }
        }
    }

    private func installRecoveryKey(_ key: RecoveryKey) async throws {
        try await model.session.installRecoveryKey(key)
        key.bytes.wipe()
    }
}
