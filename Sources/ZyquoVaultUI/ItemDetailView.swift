import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultDesign
import ZyquoVaultDomain

/// Detail column (§3.4): header card, grouped field cards, one secret revealed
/// at a time, copy with conditional clipboard clearing.
struct ItemDetailView: View {
    @Bindable var browser: BrowserModel
    @State private var revealedField: UUID?

    var body: some View {
        ZStack {
            Zyquo.color.canvas.ignoresSafeArea()
            if let item = browser.detailItem {
                detail(item)
            } else {
                ZyquoEmptyState(icon: "sidebar.right", message: "Select an item to see its details.")
            }
        }
        .onChange(of: browser.selectedItemID) { revealedField = nil }
    }

    private var totpFields: [VaultField] {
        browser.detailItem?.fields.filter { $0.kind == .totpSeed && !$0.value.reveal().isEmpty } ?? []
    }

    private func detail(_ item: VaultItem) -> some View {
        ScrollView {
            VStack(spacing: Zyquo.spacing.m) {
                headerCard(item)
                ForEach(totpFields) { field in
                    TOTPCodeCard(seedField: field, clipboard: browser.app.clipboard)
                }
                if !item.fields.isEmpty {
                    fieldsCard(item)
                }
                if let notes = item.notes, !notes.isEmpty {
                    notesCard(notes)
                }
                if item.trashedAt == nil {
                    AttachmentsCard(browser: browser, item: item)
                }
                metadataCard(item)
                if item.trashedAt != nil {
                    trashActions(item)
                }
            }
            .padding(Zyquo.spacing.l)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .bottom) { copyShortcuts(item) }
    }

    /// §10.12 secret-copy shortcuts for the selected item: ⌘⇧C password,
    /// ⌘⇧U username, ⌘⇧T one-time code. Hidden controls, keyboard-only.
    private func copyShortcuts(_ item: VaultItem) -> some View {
        Group {
            Button("") {
                if let password = item.fields.first(where: { $0.kind == .password }) {
                    browser.app.clipboard.copySecret(password.value.reveal())
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") {
                if let username = item.fields.first(where: { $0.kind == .username }) {
                    browser.app.clipboard.copySecret(username.value.reveal())
                }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("") {
                if let seed = totpFields.first,
                   let config = try? TOTPConfiguration(secret: Base32.decode(seed.value.reveal())),
                   let result = try? TOTPGenerator.code(for: config) {
                    browser.app.clipboard.copySecret(result.code)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func headerCard(_ item: VaultItem) -> some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                HStack(spacing: Zyquo.spacing.s) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                            .fill(Zyquo.color.accentSoft)
                            .frame(width: 44, height: 44)
                        Image(systemName: ItemTemplates.icon(item.itemType))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Zyquo.color.accent)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(Zyquo.type.title)
                            .foregroundStyle(Zyquo.color.inkPrimary)
                        Text(ItemTemplates.displayName(item.itemType))
                            .font(Zyquo.type.caption)
                            .foregroundStyle(Zyquo.color.inkSecondary)
                    }
                    Spacer()
                    Button {
                        Task { await browser.toggleFavorite(item.id) }
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 18))
                            .foregroundStyle(item.isFavorite ? Zyquo.color.sealGold : Zyquo.color.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isFavorite ? "Remove from favorites" : "Add to favorites")
                }
                if !item.tags.isEmpty {
                    HStack(spacing: Zyquo.spacing.xxs) {
                        ForEach(item.tags, id: \.self) { ZyquoTag($0) }
                    }
                }
                if item.trashedAt == nil {
                    HStack(spacing: Zyquo.spacing.s) {
                        ZyquoButton("Edit", role: .secondary) { browser.beginEditing(item) }
                            .keyboardShortcut("e", modifiers: .command)
                        ZyquoButton("Duplicate", role: .quiet) {
                            Task { await browser.duplicate(item.id) }
                        }
                        Spacer()
                        ZyquoButton("Move to trash", role: .quiet) {
                            Task { await browser.trash(item.id) }
                        }
                    }
                }
            }
        }
    }

    private func fieldsCard(_ item: VaultItem) -> some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                ForEach(item.fields) { field in
                    ZyquoSecretField(
                        id: field.id,
                        label: field.label,
                        value: field.value.reveal(),
                        concealable: field.isConcealed,
                        copyable: field.isCopyable,
                        revealedField: $revealedField,
                        onCopy: { browser.app.clipboard.copySecret(field.value.reveal()) }
                    )
                }
                HStack {
                    ClipboardChip(manager: browser.app.clipboard)
                    Spacer()
                    Text("⌘⇧C password · ⌘⇧U username\(totpFields.isEmpty ? "" : " · ⌘⇧T code")")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkTertiary)
                }
            }
        }
    }

    private func notesCard(_ notes: String) -> some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.xs) {
                Text("Notes")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                MarkdownNoteView(source: notes)
            }
        }
    }

    private func metadataCard(_ item: VaultItem) -> some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                metaRow("Created", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                metaRow("Modified", item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                metaRow("Revision", "\(item.revision)")
                if let folder = browser.folders.first(where: { $0.id == item.folderID }) {
                    metaRow("Folder", folder.name)
                }
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkSecondary)
        }
    }

    private func trashActions(_ item: VaultItem) -> some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                ZyquoBanner(.warning, "This item is in the trash. Restoring keeps its history; permanent deletion removes the ciphertext and its key — though older backups may still hold an encrypted copy.")
                HStack(spacing: Zyquo.spacing.s) {
                    ZyquoButton("Restore", role: .secondary) {
                        Task { await browser.restore(item.id) }
                    }
                    ZyquoButton("Delete permanently", role: .destructive) {
                        Task { await browser.deletePermanently(item.id) }
                    }
                }
            }
        }
    }
}
