import Foundation

enum NavigationItem: Hashable {
    case allItems
    case type(ItemType)
    case tag(StashTag)
    case collection(StashCollection)
    case tagGraph
    case savedSearch(SavedSearch)
    case dupes
    case stats
    case check
}
