import Foundation

struct DupeResult: Codable, Identifiable {
    var method: String
    var key: String
    var similarity: Double?
    var items: [DupeItem]

    var id: String { "\(method):\(key)" }

    var methodLabel: String {
        switch method {
        case "hash": return "Same Content"
        case "url": return "Same URL"
        case "title": return "Similar Title"
        default: return method
        }
    }

    var methodColor: String {
        switch method {
        case "hash": return "purple"
        case "url": return "red"
        case "title": return "orange"
        default: return "secondary"
        }
    }
}

struct DupeItem: Codable, Identifiable {
    var id: String
    var title: String
    var detail: String?
}
