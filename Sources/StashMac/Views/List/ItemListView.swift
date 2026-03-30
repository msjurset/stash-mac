import SwiftUI

struct ItemListView: View {
    @Environment(StashStore.self) private var store
    @Binding var showEditSheet: Bool

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedItemID) {
            HStack {
                Spacer()
                Button {
                    store.cycleSortMode()
                } label: {
                    HStack(spacing: 2) {
                        Text(store.sortMode.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: store.sortMode.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Sort: \(store.sortMode.rawValue)")
            }
            .listRowSeparator(.hidden)
            ForEach(store.items) { item in
                ItemRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Open") { store.openItem(id: item.id) }
                        Button("Edit...") {
                            store.selectedItemID = item.id
                            showEditSheet = true
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            store.deleteItem(id: item.id)
                        }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $store.searchQuery, prompt: "Search items...")
        .onSubmit(of: .search) {
            store.refresh()
        }
        .onChange(of: store.searchQuery) { _, _ in
            store.debouncedRefresh()
        }
        .overlay {
            if store.items.isEmpty && !store.isLoading {
                ContentUnavailableView("No Items", systemImage: "tray", description: Text("Add items with the + button or drag files here."))
            }
        }
        .overlay {
            if store.isLoading && store.items.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem {
                ContextualHelpButton(topic: .searching)
            }
        }
    }
}
