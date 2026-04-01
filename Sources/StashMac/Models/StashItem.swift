import Foundation

struct StashItem: Codable, Identifiable, Hashable {
    var id: String
    var type: ItemType
    var title: String
    var url: String?
    var notes: String?
    var sourcePath: String?
    var storePath: String?
    var contentHash: String?
    var extractedText: String?
    var mimeType: String?
    var fileSize: Int64?
    var metadata: [String: String]?
    var createdAt: Date
    var updatedAt: Date
    var tags: [StashTag]?
    var collections: [StashCollection]?
    var links: [StashLink]?

    var tagNames: [String] {
        tags?.map(\.name) ?? []
    }

    var collectionNames: [String] {
        collections?.map(\.name) ?? []
    }

    var shortID: String {
        if id.count > 10 {
            return String(id.prefix(10))
        }
        return id
    }

    var language: String? {
        metadata?["language"]
    }

    var humanFileSize: String? {
        guard let size = fileSize, size > 0 else { return nil }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(size)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(size) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
