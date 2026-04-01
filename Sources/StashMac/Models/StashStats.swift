import Foundation

/// JSON response from `stash stats --json`.
/// The CLI wraps the stats object with disk usage fields.
struct StashStatsResponse: Codable {
    var items: StashStatsItems
    var diskDb: Int64
    var diskFiles: Int64
    var diskTotal: Int64
}

struct StashStatsItems: Codable {
    var totalItems: Int
    var typeCounts: [String: Int]
    var totalSizeBytes: Int64
    var tagCount: Int
    var collectionCount: Int
    var linkCount: Int
    var topTags: [StashTag]
    var oldestItem: Date?
    var newestItem: Date?
    var monthCounts: [MonthCount]?
}

struct MonthCount: Codable, Identifiable {
    var month: String
    var count: Int

    var id: String { month }
}
