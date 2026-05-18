import Foundation

enum NavigationItem: Hashable {
    case allItems
    case inbox
    case type(ItemType)
    case tag(StashTag)
    case collection(StashCollection)
    case tagGraph
    case savedSearch(SavedSearch)
    case dupes
    case stats
    case check
    case rules
    case ruleActivity
    case moments
}

extension NavigationItem {
    /// Stable string token used to persist the active sidebar selection
    /// across app launches. Parameterized cases encode the lookup key
    /// (name / rawValue) since the underlying value can't be
    /// reconstructed until the store has loaded tags / collections /
    /// saved searches from the CLI.
    var persistenceKey: String {
        switch self {
        case .allItems:               return "allItems"
        case .inbox:                  return "inbox"
        case .tagGraph:               return "tagGraph"
        case .dupes:                  return "dupes"
        case .stats:                  return "stats"
        case .check:                  return "check"
        case .rules:                  return "rules"
        case .ruleActivity:           return "ruleActivity"
        case .moments:                return "moments"
        case .type(let t):            return "type:\(t.rawValue)"
        case .tag(let t):             return "tag:\(t.name)"
        case .collection(let c):      return "collection:\(c.name)"
        case .savedSearch(let s):     return "savedSearch:\(s.name)"
        }
    }

    /// Resolve a persistence key back to a NavigationItem. The store
    /// arrays must already be loaded for tag / collection /
    /// savedSearch / type lookups to succeed — call after `loadAll`.
    /// Returns nil if the key references a parameterized case whose
    /// target no longer exists (renamed / deleted) so the caller can
    /// fall back to `.allItems`.
    static func from(persistenceKey key: String,
                     tags: [StashTag],
                     collections: [StashCollection],
                     savedSearches: [SavedSearch]) -> NavigationItem? {
        switch key {
        case "allItems":      return .allItems
        case "inbox":         return .inbox
        case "tagGraph":      return .tagGraph
        case "dupes":         return .dupes
        case "stats":         return .stats
        case "check":         return .check
        case "rules":         return .rules
        case "ruleActivity":  return .ruleActivity
        // Old "trips" key folded into "moments" for the rename — any
        // user with the stale token gets routed to the renamed view
        // instead of falling back to All Items.
        case "moments", "trips": return .moments
        default: break
        }
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let kind = String(parts[0])
        let value = String(parts[1])
        switch kind {
        case "type":
            return ItemType(rawValue: value).map(NavigationItem.type)
        case "tag":
            return tags.first(where: { $0.name == value }).map(NavigationItem.tag)
        case "collection":
            return collections.first(where: { $0.name == value }).map(NavigationItem.collection)
        case "savedSearch":
            return savedSearches.first(where: { $0.name == value }).map(NavigationItem.savedSearch)
        default:
            return nil
        }
    }
}
