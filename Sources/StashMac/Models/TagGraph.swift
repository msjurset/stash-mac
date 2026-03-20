import Foundation

struct TagEdge: Codable, Identifiable {
    var tagA: String
    var tagB: String
    var weight: Int

    var id: String { "\(tagA)-\(tagB)" }
}

struct TagGraphData: Codable {
    var nodes: [StashTag]
    var edges: [TagEdge]
}
