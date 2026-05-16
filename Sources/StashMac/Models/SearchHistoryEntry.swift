import Foundation

/// One rollup row from `stash search-history list`. `count` is the
/// number of times the query has been committed (clicked from the
/// result list); `lastUsedAt` is the most-recent commit.
struct SearchHistoryEntry: Codable, Identifiable, Hashable {
    var query: String
    var count: Int
    var lastUsedAt: Date

    var id: String { query }
}
