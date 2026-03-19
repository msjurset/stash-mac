import Foundation

struct StashLink: Codable, Identifiable, Hashable {
    var itemId: String
    var title: String
    var type: ItemType
    var label: String?
    var direction: String // "none", "outgoing", "incoming"

    var id: String { itemId }

    var directionArrow: String {
        switch direction {
        case "outgoing": return "\u{2192}"
        case "incoming": return "\u{2190}"
        default: return "\u{2194}"
        }
    }
}
