import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZyquoVaultDesign
import ZyquoVaultDomain
import ZyquoVaultStorage

/// Encrypted attachments for one item (§10.8): add via file picker, open
/// (decrypts to the vault-controlled temp dir, destroyed on lock), remove.
struct AttachmentsCard: View {
    let browser: BrowserModel
    let item: VaultItem

    @State private var entries: [(id: UUID, metadata: AttachmentStore.Metadata)] = []
    @State private var importing = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        ZyquoCard(cornerRadius: Zyquo.radius.l, padding: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.s) {
                HStack {
                    Text("Attachments")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkSecondary)
                    Spacer()
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        ZyquoButton("Add file…", role: .secondary) { importing = true }
                    }
                }

                if entries.isEmpty && !working {
                    Text("No attachments. Files are encrypted in 1 MiB authenticated chunks.")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkTertiary)
                }

                ForEach(entries, id: \.id) { entry in
                    HStack(spacing: Zyquo.spacing.s) {
                        Image(systemName: "doc")
                            .foregroundStyle(Zyquo.color.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.metadata.originalFilename)
                                .font(Zyquo.type.body)
                                .foregroundStyle(Zyquo.color.inkPrimary)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.metadata.totalPlaintextSize), countStyle: .file))
                                .font(Zyquo.type.caption)
                                .foregroundStyle(Zyquo.color.inkTertiary)
                        }
                        Spacer()
                        ZyquoButton("Open", role: .quiet) { open(entry.id) }
                        ZyquoButton("Remove", role: .quiet) { remove(entry.id) }
                    }
                    .padding(Zyquo.spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                            .fill(Zyquo.color.surfaceSunken)
                    )
                }

                if !entries.isEmpty {
                    Text("Opening decrypts to a protected temp file that is destroyed on lock. Apps you open it with may keep their own copies.")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkTertiary)
                }
                if let errorMessage {
                    ZyquoBanner(.critical, errorMessage)
                }
            }
        }
        .task(id: item.id) { await refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { add(url) }
        }
    }

    private func refresh() async {
        var loaded: [(UUID, AttachmentStore.Metadata)] = []
        for id in item.attachmentIDs {
            if let metadata = try? await browser.app.session.attachmentMetadata(id: id) {
                loaded.append((id, metadata))
            }
        }
        entries = loaded
    }

    private func add(_ url: URL) {
        working = true
        errorMessage = nil
        Task {
            defer { working = false }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let stored = try await browser.app.session.storeAttachment(from: url, mimeType: mime)
                var updated = item
                updated.attachmentIDs.append(stored.id)
                await browser.saveDraft(updated)
                await refresh()
            } catch {
                errorMessage = "The file could not be attached."
            }
        }
    }

    private func open(_ id: UUID) {
        errorMessage = nil
        Task {
            do {
                let opened = try await browser.app.session.openAttachment(id: id)
                NSWorkspace.shared.open(opened.url)
            } catch {
                errorMessage = "The attachment failed verification and was not opened."
            }
        }
    }

    private func remove(_ id: UUID) {
        errorMessage = nil
        Task {
            do {
                try await browser.app.session.deleteAttachment(id: id)
                var updated = item
                updated.attachmentIDs.removeAll { $0 == id }
                await browser.saveDraft(updated)
                await refresh()
            } catch {
                errorMessage = "The attachment could not be removed."
            }
        }
    }
}
