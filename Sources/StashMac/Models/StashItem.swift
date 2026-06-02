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
    var thumbnailPath: String?
    var caption: String?
    var metadata: ItemMetadata?
    var createdAt: Date
    var updatedAt: Date
    /// When the underlying content was created in the real world —
    /// EXIF shutter time for photos, most-recent thread Date for
    /// emails, filesystem mtime for arbitrary files, the row's
    /// CreatedAt for snippets. Nil for URL items (no reliable
    /// signal) and for legacy rows that haven't been backfilled
    /// (`stash backfill-captured-at --all`). Distinct from
    /// createdAt, which records when the row landed in the stash.
    var capturedAt: Date?
    var archived: Bool?
    var location: ItemLocation?
    var files: [ItemFile]?
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
        metadata?.language
    }

    /// For email items, the sender's display name (or address if no name was
    /// supplied) parsed from the "From:" line at the top of `extractedText`.
    var fromName: String? {
        guard type == .email, let text = extractedText else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) {
            let line = String(raw)
            guard line.hasPrefix("From: ") else { continue }
            let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let lt = value.firstIndex(of: "<"), lt > value.startIndex {
                let name = value[..<lt]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty { return name }
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Apple Maps URL for this item's location, when present. Used
    /// by the detail pane's Location row and the right-click "Open
    /// in Maps" action.
    var mapsURL: URL? {
        guard let loc = location else { return nil }
        let q = "\(loc.lat),\(loc.lon)"
        return URL(string: "https://maps.apple.com/?q=\(q)")
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

/// Geolocation attached to an item. Populated automatically from
/// JPEG EXIF on capture (`source == "exif"`), from a mobile OS
/// Location API on Android capture (`source == "capture"`), or
/// set manually via the Edit dialog / `stash edit --location`
/// (`source == "manual"`).
struct ItemLocation: Codable, Hashable {
    var lat: Double
    var lon: Double
    var source: String?
}

/// Additional photo / file attached to an item beyond its primary
/// store_path. Items default to single-file (the primary lives on
/// `storePath`/`contentHash`); rows accumulate when the user
/// attaches extra angles or states of the same subject — mushroom
/// top/side/bottom, bird male/female, etc. Loaded via
/// `stash files` / `GET /items/{id}` and rendered as the carousel
/// strip in the detail pane.
struct ItemFile: Codable, Identifiable, Hashable {
    var id: Int64
    var itemId: String
    var storePath: String
    var contentHash: String
    var mimeType: String?
    var fileSize: Int64?
    var caption: String?
    var position: Int
    var createdAt: Date
}
