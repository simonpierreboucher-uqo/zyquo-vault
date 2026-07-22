import SwiftUI
import ZyquoVaultDesign
import ZyquoVaultDomain

/// The unlocked main window (§3.4): NavigationSplitView with sidebar on canvas,
/// item list and detail as floating card surfaces.
struct MainWindowView: View {
    let model: AppModel
    @State private var browser: BrowserModel
    @State private var showSettings = false
    @State private var newFolderName = ""
    @State private var addingFolder = false

    init(model: AppModel) {
        self.model = model
        self._browser = State(initialValue: BrowserModel(app: model))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
        } content: {
            ItemListView(browser: browser)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 360)
        } detail: {
            ItemDetailView(browser: browser)
        }
        .background(Zyquo.color.canvas)
        .searchable(text: $browser.searchQuery, placement: .toolbar, prompt: "Search titles, usernames, tags")
        .toolbar { toolbarContent }
        .task {
            await browser.refresh()
        }
        .onChange(of: browser.selectedItemID) {
            Task { await browser.loadDetail() }
        }
        .onChange(of: model.screen) { _, newScreen in
            if newScreen != .unlocked { browser.clearDecryptedState() }
        }
        .sheet(item: $browser.editorDraft) { draft in
            ItemEditorView(browser: browser, original: draft, isNew: browser.editorIsNew)
        }
        .sheet(isPresented: $showSettings) {
            VaultSettingsSheet(model: model)
        }
        .background { sectionShortcuts }
    }

    /// §10.12 ⌘1–4: All items, Favorites, Trash, first folder.
    private var sectionShortcuts: some View {
        Group {
            Button("") { browser.filter = .all }.keyboardShortcut("1", modifiers: .command)
            Button("") { browser.filter = .favorites }.keyboardShortcut("2", modifiers: .command)
            Button("") { browser.filter = .trash }.keyboardShortcut("3", modifiers: .command)
            Button("") {
                if let folder = browser.folders.first { browser.filter = .folder(folder.id) }
            }.keyboardShortcut("4", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Sidebar (§3.4: canvas background, rounded selection pills)

    private var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            Section {
                sidebarRow(.all, icon: "tray.full", label: "All items")
                sidebarRow(.favorites, icon: "star", label: "Favorites")
            }
            Section("Folders") {
                ForEach(browser.folders) { folder in
                    sidebarRow(.folder(folder.id), icon: "folder", label: folder.name)
                        .contextMenu {
                            Button("Delete folder", role: .destructive) {
                                Task { await browser.deleteFolder(folder.id) }
                            }
                        }
                }
                if addingFolder {
                    TextField("Folder name", text: $newFolderName)
                        .textFieldStyle(.plain)
                        .font(Zyquo.type.body)
                        .onSubmit {
                            Task {
                                await browser.addFolder(named: newFolderName)
                                newFolderName = ""
                                addingFolder = false
                            }
                        }
                } else {
                    Button {
                        addingFolder = true
                    } label: {
                        Label("New folder", systemImage: "plus")
                            .font(Zyquo.type.callout)
                            .foregroundStyle(Zyquo.color.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !browser.allTags.isEmpty {
                Section("Tags") {
                    ForEach(browser.allTags, id: \.self) { tag in
                        sidebarRow(.tag(tag), icon: "number", label: tag)
                    }
                }
            }
            Section {
                sidebarRow(.trash, icon: "trash", label: "Trash", badge: browser.trashCount)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Zyquo.color.canvas)
    }

    private var sidebarSelectionBinding: Binding<SidebarFilter?> {
        Binding(
            get: { browser.filter },
            set: { browser.filter = $0 ?? .all }
        )
    }

    private func sidebarRow(_ filter: SidebarFilter, icon: String, label: String, badge: Int? = nil) -> some View {
        Label {
            HStack {
                Text(label)
                    .font(Zyquo.type.body)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                if let badge, badge > 0 {
                    Spacer()
                    Text("\(badge)")
                        .font(Zyquo.type.caption)
                        .foregroundStyle(Zyquo.color.inkTertiary)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Zyquo.color.accent)
        }
        .tag(filter)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(VaultItemType.allCases, id: \.self) { type in
                    Button {
                        browser.beginNewItem(type)
                    } label: {
                        Label(ItemTemplates.displayName(type), systemImage: ItemTemplates.icon(type))
                    }
                }
            } label: {
                Label("New item", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New item (⌘N)")
        }
        ToolbarItem {
            Button {
                model.lockNow()
            } label: {
                Label("Lock", systemImage: "lock")
            }
            .keyboardShortcut("l", modifiers: .command)
            .help("Lock the vault (⌘L)")
        }
        ToolbarItem {
            Button {
                showSettings = true
            } label: {
                Label("Vault settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Vault settings (⌘,)")
        }
    }
}
