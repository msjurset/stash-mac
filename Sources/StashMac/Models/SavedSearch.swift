import Foundation

struct SavedSearch: Codable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var query: String
    var filter: SearchFilter

    struct SearchFilter: Codable, Hashable {
        var type: String?
        var tags: [String]?
        var collection: String?
        var limit: Int?
    }

    var summary: String {
        var parts: [String] = []
        if !query.isEmpty { parts.append(query) }
        if let t = filter.type, !t.isEmpty { parts.append("type:\(t)") }
        if let tags = filter.tags {
            for tag in tags { parts.append("tag:\(tag)") }
        }
        if let c = filter.collection, !c.isEmpty { parts.append("col:\(c)") }
        return parts.joined(separator: " ")
    }
}
