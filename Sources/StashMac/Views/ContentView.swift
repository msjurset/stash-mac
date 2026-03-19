import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(StashStore.self) private var store
    @State private var showAddSheet = false
    @State private var showAddCollectionSheet = false
    @State private var showEditSheet = false
    @State private var showQuickSearch = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $store.navigation,
                showAddCollectionSheet: $showAddCollectionSheet
            )
        } content: {
            ItemListView(showEditSheet: $showEditSheet)
        } detail: {
            DetailRouter(showEditSheet: $showEditSheet)
        }
        .onAppear {
            store.loadAll()
        }
        .onChange(of: store.navigation) { _, newValue in
            store.handleNavigationChange(newValue ?? .allItems)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(isPresented: $showAddSheet) {
            AddItemSheet()
        }
        .sheet(isPresented: $showAddCollectionSheet) {
            AddCollectionSheet()
        }
        .sheet(isPresented: $showEditSheet) {
            if let item = store.selectedItem {
                EditItemSheet(item: item)
            }
        }
        .sheet(isPresented: $showQuickSearch) {
            QuickSearchView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("Add new item (⌘N)")
            }
        }
        .keyboardShortcut("k", modifiers: .command) {
            showQuickSearch = true
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    store.addFile(path: url.path, title: nil, tags: [], note: nil, collection: nil)
                }
            }
        }
    }
}

private extension View {
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        background(
            Button("") { action() }
                .keyboardShortcut(key, modifiers: modifiers)
                .hidden()
        )
    }
}
