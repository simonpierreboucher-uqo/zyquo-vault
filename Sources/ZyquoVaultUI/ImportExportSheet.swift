import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZyquoVaultCrypto
import ZyquoVaultDesign
import ZyquoVaultDomain
import ZyquoVaultImport
import ZyquoVaultStorage

/// Import / export flows (§10.9). Everything runs locally; plaintext export
/// hides behind an explicit typed confirmation.
struct ImportExportSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    // Import state
    @State private var importing = false
    @State private var pendingItems: [VaultItem] = []
    @State private var pendingFolders: [VaultFolder] = []
    @State private var pendingSource = ""
    @State private var duplicateIDs: Set<UUID> = []
    @State private var skipDuplicates = true
    @State private var zyquoImportData: Data?
    @State private var zyquoImportPassword = ""
    @State private var status: String?
    @State private var working = false
    // Export state
    @State private var exportPassword = ""
    @State private var exportConfirmation = ""
    @State private var plaintextConfirmation = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Zyquo.spacing.l) {
                HStack {
                    Text("Import & export")
                        .font(Zyquo.type.title)
                        .foregroundStyle(Zyquo.color.inkPrimary)
                    Spacer()
                    ZyquoButton("Done", role: .secondary) { dismiss() }
                }

                importCard
                if !pendingItems.isEmpty { previewCard }
                if zyquoImportData != nil { zyquoPasswordCard }
                encryptedExportCard
                plaintextExportCard

                if let status {
                    ZyquoBanner(status.hasPrefix("OK") ? .info : .critical, status)
                }
            }
            .padding(Zyquo.spacing.xl)
        }
        .frame(width: 520, height: 640)
        .background(Zyquo.color.canvas)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.commaSeparatedText, .json, .data]
        ) { result in
            if case .success(let url) = result { load(url) }
        }
    }

    // MARK: Import

    private var importCard: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                Text("Import")
                    .font(Zyquo.type.headline)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                Text("Supported: generic or browser CSV, Bitwarden unencrypted JSON, and encrypted Zyquo exports (.zyquoexport). The file is parsed on this Mac only — nothing is uploaded, nothing is logged.")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkTertiary)
                ZyquoBanner(.warning, "An export file holds secrets in a weaker form than the vault. After a successful import, delete the source file — and note that SSD wear-leveling and backups may retain traces regardless.")
                ZyquoButton("Choose a file…", role: .secondary) { importing = true }
            }
        }
    }

    private var previewCard: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                Text("Ready to import — \(pendingSource)")
                    .font(Zyquo.type.headline)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                let byType = Dictionary(grouping: pendingItems, by: \.itemType)
                ForEach(byType.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { type in
                    Text("\(byType[type]!.count) × \(ItemTemplates.displayName(type))")
                        .font(Zyquo.type.callout)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                }
                if !pendingFolders.isEmpty {
                    Text("\(pendingFolders.count) folder(s) will be created")
                        .font(Zyquo.type.callout)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                }
                if !duplicateIDs.isEmpty {
                    Toggle("Skip \(duplicateIDs.count) likely duplicate(s) (same type, title, and username)", isOn: $skipDuplicates)
                        .toggleStyle(.checkbox)
                        .font(Zyquo.type.callout)
                }
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    HStack {
                        ZyquoButton("Cancel", role: .quiet) {
                            pendingItems = []
                            pendingFolders = []
                        }
                        ZyquoButton("Import \(importCount) item(s)", fullWidth: true, action: commitImport)
                    }
                }
            }
        }
    }

    private var importCount: Int {
        skipDuplicates ? pendingItems.count - duplicateIDs.count : pendingItems.count
    }

    private var zyquoPasswordCard: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                Text("Encrypted Zyquo export")
                    .font(Zyquo.type.headline)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                ZyquoSecureField("Export password", text: $zyquoImportPassword, onSubmit: decryptZyquoImport)
                ZyquoButton("Decrypt", fullWidth: true, action: decryptZyquoImport)
            }
        }
    }

    private func load(_ url: URL) {
        status = nil
        pendingItems = []
        pendingFolders = []
        zyquoImportData = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            status = "The file could not be read."
            return
        }
        if url.pathExtension.lowercased() == ZyquoExport.fileExtension
            || data.prefix(4).elementsEqual(ZyquoExport.magic) {
            zyquoImportData = data
            return
        }
        // Try Bitwarden JSON first (self-describing), then CSV.
        if let result = try? BitwardenJSONImporter().parseWithFolders(data) {
            stage(items: result.items, folders: result.folders, source: "Bitwarden JSON")
            return
        }
        do {
            let items = try GenericCSVImporter().parse(data)
            stage(items: items, folders: [], source: "CSV")
        } catch let error as ImportError {
            status = describe(error)
        } catch {
            status = "The file format was not recognized."
        }
    }

    private func decryptZyquoImport() {
        guard let data = zyquoImportData, !zyquoImportPassword.isEmpty else { return }
        working = true
        status = nil
        let password = SecureBytes(utf8: zyquoImportPassword)
        Task.detached(priority: .userInitiated) {
            defer { password.wipe() }
            do {
                let payload = try ZyquoExport.open(data, password: password)
                await MainActor.run {
                    working = false
                    zyquoImportData = nil
                    zyquoImportPassword = ""
                    // Re-identify so an import never collides with existing UUIDs.
                    let items = payload.items.map { item in
                        var copy = item
                        copy = VaultItem(
                            itemType: item.itemType, title: item.title, subtitle: item.subtitle,
                            fields: item.fields.map { VaultField(label: $0.label, value: $0.value, kind: $0.kind, isConcealed: $0.isConcealed, isCopyable: $0.isCopyable) },
                            notes: item.notes, tags: item.tags, folderID: item.folderID,
                            isFavorite: item.isFavorite
                        )
                        return copy
                    }
                    stage(items: items, folders: payload.folders, source: "Zyquo encrypted export")
                }
            } catch {
                await MainActor.run {
                    working = false
                    status = "The password is incorrect or the export file is damaged."
                }
            }
        }
    }

    private func stage(items: [VaultItem], folders: [VaultFolder], source: String) {
        pendingItems = items
        pendingFolders = folders
        pendingSource = source
        Task {
            let existing = (try? await model.session.summaries()) ?? []
            let keys = Set(existing.map { "\($0.itemType.rawValue)|\($0.title.lowercased())|\(($0.subtitle ?? "").lowercased())" })
            duplicateIDs = Set(items.filter { item in
                let username = item.fields.first { $0.kind == .username }?.value.reveal() ?? ""
                return keys.contains("\(item.itemType.rawValue)|\(item.title.lowercased())|\(username.lowercased())")
            }.map(\.id))
        }
    }

    private func commitImport() {
        working = true
        status = nil
        Task {
            defer { working = false }
            do {
                if !pendingFolders.isEmpty {
                    let existing = try await model.session.folders()
                    try await model.session.setFolders(existing + pendingFolders)
                }
                var imported = 0
                for item in pendingItems where !(skipDuplicates && duplicateIDs.contains(item.id)) {
                    try await model.session.save(item)
                    imported += 1
                }
                pendingItems = []
                pendingFolders = []
                status = "OK — imported \(imported) item(s). Consider deleting the source file now."
            } catch {
                status = "The import stopped early; already-imported items were kept. Try again to finish."
            }
        }
    }

    private func describe(_ error: ImportError) -> String {
        switch error {
        case .unreadableFile: "The file could not be read."
        case .unrecognizedFormat(let reason): "The file was not recognized: \(reason)."
        case .emptyImport: "No importable items were found in the file."
        }
    }

    // MARK: Encrypted export

    private var encryptedExportCard: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                Text("Encrypted export (recommended)")
                    .font(Zyquo.type.headline)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                Text("Creates a self-contained .zyquoexport file protected by its own password (Argon2id + AES-256-GCM).")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkTertiary)
                ZyquoSecureField("Export password", text: $exportPassword)
                ZyquoSecureField("Confirm export password", text: $exportConfirmation)
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    ZyquoButton("Export encrypted…", role: .secondary, action: exportEncrypted)
                }
            }
        }
    }

    private func exportEncrypted() {
        guard !exportPassword.isEmpty else { status = "An export password is required."; return }
        guard exportPassword == exportConfirmation else { status = "The export passwords do not match."; return }
        working = true
        status = nil
        let password = SecureBytes(utf8: exportPassword)
        Task {
            defer { working = false }
            do {
                let items = try await model.session.items()
                let folders = try await model.session.folders()
                let payload = ZyquoExport.Payload(
                    exportedAt: UInt64(Date().timeIntervalSince1970),
                    items: items, folders: folders
                )
                let data = try await Task.detached(priority: .userInitiated) {
                    defer { password.wipe() }
                    return try ZyquoExport.seal(payload: payload, password: password)
                }.value
                savePanel(suggested: "vault.\(ZyquoExport.fileExtension)", data: data)
                exportPassword = ""
                exportConfirmation = ""
                status = "OK — encrypted export written."
            } catch {
                password.wipe()
                status = "The export could not be created."
            }
        }
    }

    // MARK: Plaintext export (warning-gated)

    private var plaintextExportCard: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                Text("Plaintext export")
                    .font(Zyquo.type.headline)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                ZyquoBanner(.critical, "A plaintext export contains every secret unprotected. Anyone who reads the file gets everything. Delete it immediately after use; SSDs and backups may retain traces regardless.")
                Text("Type EXPORT to enable:")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                ZyquoSecureField("Confirmation", text: $plaintextConfirmation, allowReveal: true)
                HStack(spacing: Zyquo.spacing.s) {
                    ZyquoButton("Export JSON…", role: .destructive) { exportPlaintext(json: true) }
                    ZyquoButton("Export CSV…", role: .destructive) { exportPlaintext(json: false) }
                }
                .disabled(plaintextConfirmation != "EXPORT")
                .opacity(plaintextConfirmation == "EXPORT" ? 1 : 0.4)
            }
        }
    }

    private func exportPlaintext(json: Bool) {
        guard plaintextConfirmation == "EXPORT" else { return }
        status = nil
        Task {
            do {
                let items = try await model.session.items()
                let folders = try await model.session.folders()
                let data = json
                    ? try PlaintextExport.json(items: items, folders: folders)
                    : PlaintextExport.csv(items: items)
                savePanel(suggested: json ? "vault-plaintext.json" : "vault-plaintext.csv", data: data)
                plaintextConfirmation = ""
                status = "OK — plaintext export written. Delete it as soon as you are done with it."
            } catch {
                status = "The export could not be created."
            }
        }
    }

    private func savePanel(suggested: String, data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .withoutOverwriting)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
