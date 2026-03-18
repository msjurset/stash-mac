import SwiftUI

struct SidebarView: View {
    @Environment(StashStore.self) private var store
    @Binding var selection: NavigationItem?
    @Binding var showAddCollectionSheet: Bool
    @State private var renamingTag: StashTag?
    @State private var newTagName = ""

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Items", systemImage: "tray.full")
                    .tag(NavigationItem.allItems)
                ForEach(ItemType.allCases) { type in
                    Label(type.label, systemImage: type.icon)
                        .tag(NavigationItem.type(type))
                }
            }

            Section("Tags") {
                ForEach(store.tags) { tag in
                    Label(tag.name, systemImage: "tag")
                        .tag(NavigationItem.tag(tag))
                        .contextMenu {
                            Button("Rename...") {
                                renamingTag = tag
                                newTagName = tag.name
                            }
                        }
                }
                if store.tags.isEmpty {
                    Text("No tags yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Collections") {
                ForEach(store.collections) { col in
                    Label(col.name, systemImage: "folder")
                        .tag(NavigationItem.collection(col))
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.deleteCollection(name: col.name)
                            }
                        }
                }
                Button {
                    showAddCollectionSheet = true
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Stash")
        .alert("Rename Tag", isPresented: .init(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )) {
            TextField("New name", text: $newTagName)
            Button("Rename") {
                if let tag = renamingTag, !newTagName.isEmpty {
                    store.renameTag(old: tag.name, new: newTagName)
                }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) {
                renamingTag = nil
            }
        }
    }
}
