import SwiftUI
import ZyquoVaultDesign
import ZyquoVaultDomain

/// Item editor sheet (§10.3): dynamic reorderable fields, custom fields with
/// conceal toggles, tags, folder picker, notes, unsaved-changes guard.
struct ItemEditorView: View {
    let browser: BrowserModel
    let original: VaultItem
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: VaultItem
    @State private var tagInput = ""
    @State private var showDiscardDialog = false
    @State private var revealedFieldIDs: Set<UUID> = []
    @State private var generatorFieldID: UUID?

    init(browser: BrowserModel, original: VaultItem, isNew: Bool) {
        self.browser = browser
        self.original = original
        self.isNew = isNew
        self._draft = State(initialValue: original)
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Zyquo.color.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Zyquo.spacing.l) {
                    titleSection
                    fieldsSection
                    tagsSection
                    organizationSection
                    notesSection
                }
                .padding(Zyquo.spacing.xl)
            }
            Divider().overlay(Zyquo.color.hairline)
            footer
        }
        .frame(width: 560, height: 640)
        .background(Zyquo.color.canvas)
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showDiscardDialog,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text(isNew ? "New \(ItemTemplates.displayName(draft.itemType).lowercased())" : "Edit item")
                .font(Zyquo.type.title)
                .foregroundStyle(Zyquo.color.inkPrimary)
            Spacer()
            Image(systemName: ItemTemplates.icon(draft.itemType))
                .foregroundStyle(Zyquo.color.accent)
        }
        .padding(Zyquo.spacing.l)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            fieldLabel("Title")
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(Zyquo.type.body)
                .padding(.vertical, Zyquo.spacing.xs)
                .padding(.horizontal, Zyquo.spacing.s)
                .background(well)
            if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("A title is required.")
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.caution)
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xs) {
            fieldLabel("Fields")
            List {
                ForEach($draft.fields) { $field in
                    fieldEditor($field)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                }
                .onMove { indices, offset in
                    draft.fields.move(fromOffsets: indices, toOffset: offset)
                }
                .onDelete { indices in
                    draft.fields.remove(atOffsets: indices)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: max(56, CGFloat(draft.fields.count) * 64))

            ZyquoButton("Add field", role: .secondary) {
                draft.fields.append(VaultField(
                    label: "Custom field",
                    value: SensitiveFieldValue(""),
                    kind: .custom
                ))
            }
            Text("Drag to reorder. Swipe or ⌫ to remove.")
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkTertiary)
        }
    }

    private func fieldEditor(_ field: Binding<VaultField>) -> some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            HStack(spacing: Zyquo.spacing.xs) {
                TextField("Label", text: field.label)
                    .textFieldStyle(.plain)
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
                Spacer()
                Toggle("Conceal", isOn: field.isConcealed)
                    .toggleStyle(.checkbox)
                    .font(Zyquo.type.caption)
                    .foregroundStyle(Zyquo.color.inkSecondary)
            }
            secretValueField(field)
        }
        .padding(Zyquo.spacing.xs)
        .background(well)
    }

    private func secretValueField(_ field: Binding<VaultField>) -> some View {
        let textBinding = Binding<String>(
            get: { field.wrappedValue.value.reveal() },
            set: { field.wrappedValue.value = SensitiveFieldValue($0) }
        )
        let id = field.wrappedValue.id
        let concealedNow = field.wrappedValue.isConcealed && !revealedFieldIDs.contains(id)
        return HStack(spacing: Zyquo.spacing.xs) {
            Group {
                if concealedNow {
                    SecureField("Value", text: textBinding)
                } else {
                    TextField("Value", text: textBinding, axis: field.wrappedValue.kind == .multiline ? .vertical : .horizontal)
                }
            }
            .textFieldStyle(.plain)
            .font(Zyquo.type.mono)
            if field.wrappedValue.isConcealed {
                Button {
                    if revealedFieldIDs.contains(id) {
                        revealedFieldIDs.remove(id)
                    } else {
                        revealedFieldIDs.insert(id)
                    }
                } label: {
                    Image(systemName: concealedNow ? "eye" : "eye.slash")
                        .foregroundStyle(Zyquo.color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(concealedNow ? "Reveal value" : "Conceal value")
            }
            if field.wrappedValue.isConcealed || field.wrappedValue.kind == .password {
                Button {
                    generatorFieldID = id
                } label: {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Zyquo.color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Generate a value for \(field.wrappedValue.label)")
                .popover(isPresented: Binding(
                    get: { generatorFieldID == id },
                    set: { if !$0 { generatorFieldID = nil } }
                )) {
                    GeneratorPopover { value in
                        field.wrappedValue.value = SensitiveFieldValue(value)
                        generatorFieldID = nil
                    }
                }
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            fieldLabel("Tags")
            HStack(spacing: Zyquo.spacing.xxs) {
                ForEach(draft.tags, id: \.self) { tag in
                    ZyquoTag(tag) {
                        draft.tags.removeAll { $0 == tag }
                    }
                }
                TextField("Add tag…", text: $tagInput)
                    .textFieldStyle(.plain)
                    .font(Zyquo.type.caption)
                    .frame(minWidth: 80)
                    .onSubmit {
                        let tag = tagInput.trimmingCharacters(in: .whitespaces)
                        if !tag.isEmpty, !draft.tags.contains(tag) {
                            draft.tags.append(tag)
                        }
                        tagInput = ""
                    }
            }
            .padding(Zyquo.spacing.xs)
            .background(well)
        }
    }

    private var organizationSection: some View {
        HStack(spacing: Zyquo.spacing.l) {
            VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
                fieldLabel("Folder")
                Picker("Folder", selection: $draft.folderID) {
                    Text("None").tag(UUID?.none)
                    ForEach(browser.folders) { folder in
                        Text(folder.name).tag(UUID?.some(folder.id))
                    }
                }
                .labelsHidden()
            }
            Toggle(isOn: $draft.isFavorite) {
                Label("Favorite", systemImage: "star")
                    .font(Zyquo.type.callout)
            }
            .toggleStyle(.checkbox)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xxs) {
            fieldLabel("Notes")
            TextEditor(text: Binding(
                get: { draft.notes ?? "" },
                set: { draft.notes = $0.isEmpty ? nil : $0 }
            ))
            .font(Zyquo.type.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 80)
            .padding(Zyquo.spacing.xs)
            .background(well)
        }
    }

    private var footer: some View {
        HStack {
            ZyquoButton("Cancel", role: .quiet) {
                if hasChanges {
                    showDiscardDialog = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            ZyquoButton(isNew ? "Create" : "Save") {
                guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Task { await browser.saveDraft(draft) }
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(Zyquo.spacing.l)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Zyquo.type.caption)
            .foregroundStyle(Zyquo.color.inkSecondary)
    }

    private var well: some View {
        RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
            .fill(Zyquo.color.surfaceSunken)
    }
}
