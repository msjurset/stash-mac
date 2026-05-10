import Foundation
import Testing

@testable import StashMac

/// Covers `StashStore.selectItemByID` — the entry point QuickSearchView,
/// CheckView, DupesView, and SuggestRulesSheet all use to focus an item
/// in the detail pane. Today's regression (Health Check item-clicks
/// jumping nav to All Items) was a one-line bug in this method that no
/// test caught; this suite locks in the contract.
@MainActor
@Suite("StashStore selectItemByID")
struct StashStoreSelectionTests {
    @Test("Sets selectedItemID and selectedItems")
    func setsBothSelectionFields() {
        let store = makeStore(items: [item("A"), item("B")])
        store.selectItemByID("A")
        #expect(store.selectedItemID == "A")
        #expect(store.selectedItems == ["A"])
    }

    @Test("Default revealInList=false leaves navigation alone")
    func defaultDoesNotChangeNav() {
        let store = makeStore(items: [item("A")], navigation: .check)
        store.selectItemByID("A")
        #expect(store.navigation == .check)
    }

    @Test("revealInList=true keeps current nav when item is visible there")
    func revealKeepsNavWhenVisible() {
        let store = makeStore(items: [item("A")], navigation: .check)
        store.selectItemByID("A", revealInList: true)
        #expect(store.navigation == .check)
    }

    @Test("revealInList=true switches to All Items when item is not visible in current scope")
    func revealSwitchesNavWhenNotVisible() {
        let store = makeStore(items: [], navigation: .check)
        store.selectItemByID("Z", revealInList: true)
        #expect(store.navigation == .allItems)
    }

    @Test("revealInList=true on All Items stays on All Items")
    func revealStaysOnAllItemsWhenAlreadyThere() {
        let store = makeStore(items: [], navigation: .allItems)
        store.selectItemByID("Z", revealInList: true)
        #expect(store.navigation == .allItems)
    }

    @Test("Replaces prior multi-selection with single selection")
    func replacesMultiSelection() {
        let store = makeStore(items: [item("A"), item("B"), item("C")])
        store.selectedItems = ["A", "B"]
        store.selectItemByID("C")
        #expect(store.selectedItems == ["C"])
        #expect(store.selectedItemID == "C")
    }

    // MARK: - Helpers

    private func makeStore(items: [StashItem] = [], navigation: NavigationItem? = .allItems) -> StashStore {
        let store = StashStore()
        store.items = items
        store.navigation = navigation
        return store
    }

    private func item(_ id: String) -> StashItem {
        StashItem(
            id: id,
            type: .url,
            title: id,
            url: "https://example.com/\(id.lowercased())",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
