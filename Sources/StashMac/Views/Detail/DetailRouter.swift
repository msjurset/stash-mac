import SwiftUI

struct DetailRouter: View {
    @Environment(StashStore.self) private var store
    @Binding var showEditSheet: Bool

    var body: some View {
        if let item = store.selectedItem {
            ItemDetailView(item: item, showEditSheet: $showEditSheet)
        } else {
            ContentUnavailableView("Select an Item", systemImage: "doc.text.magnifyingglass", description: Text("Choose an item from the list to view its details."))
        }
    }
}
