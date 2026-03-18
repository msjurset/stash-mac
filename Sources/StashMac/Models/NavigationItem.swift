import Foundation

enum NavigationItem: Hashable {
    case allItems
    case type(ItemType)
    case tag(StashTag)
    case collection(StashCollection)
}
