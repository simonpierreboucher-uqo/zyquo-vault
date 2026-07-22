import SwiftUI
import ZyquoVaultDesign
import ZyquoVaultDomain

/// Middle column: the item list as a floating card surface on canvas (§3.4).
struct ItemListView: View {
    @Bindable var browser: BrowserModel

    var body: some View {
        ZStack {
            Zyquo.color.canvas.ignoresSafeArea()
            content
                .background(
                    RoundedRectangle(cornerRadius: Zyquo.radius.l, style: .continuous)
                        .fill(Zyquo.color.surface)
                )
                .zyquoShadow(Zyquo.elevation.level1)
                .padding(Zyquo.spacing.s)
        }
    }

    @ViewBuilder
    private var content: some View {
        if browser.visibleSummaries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: Zyquo.spacing.xxs) {
                    if case .trash = browser.filter, browser.trashCount > 0 {
                        trashHeader
                    }
                    ForEach(browser.visibleSummaries) { summary in
                        Button {
                            browser.selectedItemID = summary.id
                        } label: {
                            ZyquoListRow(
                                icon: ItemTemplates.icon(summary.itemType),
                                title: summary.title,
                                subtitle: summary.subtitle,
                                trailing: summary.updatedAt.formatted(.relative(presentation: .named)),
                                isFavorite: summary.isFavorite,
                                selected: browser.selectedItemID == summary.id
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: summary) }
                    }
                }
                .padding(Zyquo.spacing.xs)
            }
        }
    }

    private var trashHeader: some View {
        HStack {
            Text("Items in the trash stay encrypted.")
                .font(Zyquo.type.caption)
                .foregroundStyle(Zyquo.color.inkTertiary)
            Spacer()
            ZyquoButton("Empty trash", role: .destructive) {
                Task { await browser.emptyTrash() }
            }
        }
        .padding(.horizontal, Zyquo.spacing.xs)
        .padding(.top, Zyquo.spacing.xs)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch browser.filter {
        case .trash:
            ZyquoEmptyState(icon: "trash", message: "The trash is empty.")
        case .favorites:
            ZyquoEmptyState(icon: "star", message: "No favorites yet. Star an item to keep it at hand.")
        default:
            if browser.searchQuery.isEmpty {
                ZyquoEmptyState(
                    icon: "tray",
                    message: "Nothing here yet.",
                    actionTitle: "New login"
                ) {
                    browser.beginNewItem(.login)
                }
            } else {
                ZyquoEmptyState(icon: "magnifyingglass", message: "No items match “\(browser.searchQuery)”.")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for summary: ItemSummary) -> some View {
        if summary.isTrashed {
            Button("Restore") { Task { await browser.restore(summary.id) } }
            Button("Delete permanently", role: .destructive) {
                Task { await browser.deletePermanently(summary.id) }
            }
        } else {
            Button(summary.isFavorite ? "Remove from favorites" : "Add to favorites") {
                Task { await browser.toggleFavorite(summary.id) }
            }
            Button("Duplicate") { Task { await browser.duplicate(summary.id) } }
            Button("Move to trash", role: .destructive) {
                Task { await browser.trash(summary.id) }
            }
        }
    }
}
