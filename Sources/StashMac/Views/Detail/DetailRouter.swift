import SwiftUI

struct DetailRouter: View {
    @Environment(StashStore.self) private var store
    @Binding var showEditSheet: Bool

    @State private var debouncedItem: StashItem? = nil

    var body: some View {
        Group {
            if let item = debouncedItem {
                ItemDetailView(item: item, showEditSheet: $showEditSheet)
            } else {
                ContentUnavailableView("Select an Item", systemImage: "doc.text.magnifyingglass", description: Text("Choose an item from the list to view its details."))
            }
        }
        .task(id: store.selectedItemID) {
            do {
                if store.selectedItemID == nil {
                    debouncedItem = nil
                    return
                }
                
                // Debounce selection by 100ms: if arrowing down rapidly, 
                // the intermediate detail views will never load or block rendering.
                try await Task.sleep(nanoseconds: 100 * 1_000_000)
                
                debouncedItem = store.selectedItem
            } catch {
                // Task cancelled on selection change
            }
        }
        .onAppear {
            debouncedItem = store.selectedItem
        }
    }
}
