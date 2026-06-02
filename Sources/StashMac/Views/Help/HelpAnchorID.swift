import SwiftUI

/// Identifiers for UI elements that can be spotlighted in the Help Overlay.
enum HelpAnchorID: String, Hashable, CaseIterable {
    case sidebar
    case navigationList
    case searchBar
    case itemDetail
    case filterBar
    case addButton
    
    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .navigationList: return "Item List"
        case .searchBar: return "Search"
        case .itemDetail: return "Item Detail"
        case .filterBar: return "Filter Bar"
        case .addButton: return "Add Button"
        }
    }
    
    var description: String {
        switch self {
        case .sidebar:
            return "Switch between your Library, Tags, Collections, and specialized views like Inbox or Trash."
        case .navigationList:
            return "Browse your items. Click to select, or use keyboard arrows to navigate."
        case .searchBar:
            return "Search across everything. Supports full-text, tags (tag:name), and advanced filters."
        case .itemDetail:
            return "View and edit item details, notes, and tags. Open links or files externally from here."
        case .filterBar:
            return "Quickly filter the list by item type (URL, File, Image, etc.)."
        case .addButton:
            return "Manually add a URL, file, or text snippet to your stash."
        }
    }
    
    var topic: HelpTopic {
        switch self {
        case .sidebar: return .organizing
        case .navigationList: return .gettingStarted
        case .searchBar: return .searching
        case .itemDetail: return .itemDetail
        case .filterBar: return .searching
        case .addButton: return .addingItems
        }
    }
}
