import Foundation

struct StashTag: Codable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var count: Int?

    // Hash/equatable based on id and name only (not count) for sidebar selection
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }

    static func == (lhs: StashTag, rhs: StashTag) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}
