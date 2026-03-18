import SwiftUI

struct ItemListView: View {
    @Environment(StashStore.self) private var store
    @Binding var showEditSheet: Bool

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedItemID) {
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
        .searchable(text: $store.searchQuery, prompt: "Filter items...")
        .onSubmit(of: .search) {
            store.refresh()
        }
        .onChange(of: store.searchQuery) { _, query in
            if query.isEmpty {
                store.refresh()
            }
        }
        .overlay {
            if store.items.isEmpty && !store.isLoading {
                ContentUnavailableView("No Items", systemImage: "tray", description: Text("Add items with the + button or drag files here."))
            }
        }
        .overlay {
            if store.isLoading {
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
