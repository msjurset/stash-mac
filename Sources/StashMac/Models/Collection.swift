import Foundation

struct StashCollection: Codable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var description: String?
}
