import AppKit
import Observation
import SwiftUI
import ZyquoVaultDomain
import ZyquoVaultStorage

/// Sidebar scopes (§3.4). Folders and tags are dynamic sections.
enum SidebarFilter: Hashable {
    case all
    case favorites
    case folder(UUID)
    case tag(String)
    case trash
}

/// State for the unlocked three-pane browser. Holds only non-secret summaries
/// plus the currently selected decrypted item; everything is discarded on lock.
@MainActor
@Observable
final class BrowserModel {
    let app: AppModel

    var summaries: [ItemSummary] = []
    var folders: [VaultFolder] = []
    var filter: SidebarFilter = .all
    var selectedItemID: UUID?
    var searchQuery = ""
    var detailItem: VaultItem?
    var editorDraft: VaultItem?
    var editorIsNew = false
    var errorMessage: String?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Derived collections

    var visibleSummaries: [ItemSummary] {
        summaries.filter { summary in
            let scoped: Bool = switch filter {
            case .all: !summary.isTrashed
            case .favorites: summary.isFavorite && !summary.isTrashed
            case .folder(let id): summary.folderID == id && !summary.isTrashed
            case .tag(let tag): summary.tags.contains(tag) && !summary.isTrashed
            case .trash: summary.isTrashed
            }
            return scoped && summary.matches(searchQuery)
        }
    }

    var allTags: [String] {
        Array(Set(summaries.filter { !$0.isTrashed }.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var trashCount: Int { summaries.filter(\.isTrashed).count }

    // MARK: Loading

    func refresh() async {
        do {
            summaries = try await app.session.summaries()
            folders = try await app.session.folders()
            if let selectedItemID, !summaries.contains(where: { $0.id == selectedItemID }) {
                self.selectedItemID = nil
                detailItem = nil
            }
        } catch {
            summaries = []
            folders = []
        }
    }

    func loadDetail() async {
        guard let selectedItemID else {
            detailItem = nil
            return
        }
        detailItem = try? await app.session.item(id: selectedItemID)
    }

    /// Called on lock: drop every decrypted value this model holds (§8.3).
    func clearDecryptedState() {
        summaries = []
        folders = []
        detailItem = nil
        editorDraft = nil
        selectedItemID = nil
        searchQuery = ""
    }

    // MARK: Item actions

    func beginNewItem(_ type: VaultItemType) {
        var item = VaultItem(itemType: type, title: "", fields: ItemTemplates.starterFields(type))
        if case .folder(let id) = filter { item.folderID = id }
        if case .tag(let tag) = filter { item.tags = [tag] }
        editorIsNew = true
        editorDraft = item
    }

    func beginEditing(_ item: VaultItem) {
        editorIsNew = false
        editorDraft = item
    }

    func saveDraft(_ draft: VaultItem) async {
        do {
            try await app.session.save(draft)
            editorDraft = nil
            await refresh()
            selectedItemID = draft.id
            await loadDetail()
        } catch {
            errorMessage = "The item could not be saved."
        }
    }

    func toggleFavorite(_ id: UUID) async {
        guard var item = try? await app.session.item(id: id) else { return }
        item.isFavorite.toggle()
        try? await app.session.save(item)
        await refresh()
        await loadDetail()
    }

    func trash(_ id: UUID) async {
        try? await app.session.trash(id: id)
        selectedItemID = nil
        detailItem = nil
        await refresh()
    }

    func restore(_ id: UUID) async {
        try? await app.session.restore(id: id)
        await refresh()
        await loadDetail()
    }

    func deletePermanently(_ id: UUID) async {
        try? await app.session.deletePermanently(id: id)
        selectedItemID = nil
        detailItem = nil
        await refresh()
    }

    func emptyTrash() async {
        try? await app.session.emptyTrash()
        selectedItemID = nil
        detailItem = nil
        await refresh()
    }

    func duplicate(_ id: UUID) async {
        if let copy = try? await app.session.duplicate(id: id) {
            await refresh()
            selectedItemID = copy.id
            await loadDetail()
        }
    }

    // MARK: Folders

    func addFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var updated = folders
        updated.append(VaultFolder(name: trimmed))
        try? await app.session.setFolders(updated)
        await refresh()
    }

    func deleteFolder(_ id: UUID) async {
        // Items keep their folderID; an orphaned folderID simply stops filtering.
        try? await app.session.setFolders(folders.filter { $0.id != id })
        if case .folder(let selected) = filter, selected == id { filter = .all }
        await refresh()
    }

}
