import Foundation

/// A watched feed subscription. Mirrors the Go-side `model.FeedSource`.
/// JSON keys are snake_case on the CLI side; the shared decoder has
/// `keyDecodingStrategy = .convertFromSnakeCase` so the camelCase Swift
/// property names match incoming wire data without explicit CodingKeys.
struct FeedSource: Codable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var kind: String
    var url: String
    var defaultTags: [String]?
    var defaultCollection: String?
    var autoStash: Bool?
    var pollIntervalMinutes: Int
    var enabled: Bool
    var lastPolledAt: Date?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
}

/// One candidate entry pulled from a feed source, awaiting triage.
/// State machine: unread → stashed | dismissed | snoozed. Snoozed rows
/// flip back to unread on the next poll once snoozeUntil passes.
struct FeedCandidate: Codable, Identifiable, Hashable {
    var id: Int64
    var sourceId: Int64
    var sourceName: String?
    var guid: String
    var url: String
    var title: String?
    var description: String?
    /// Markdown-converted form of `description`, cached at poll time by
    /// the Go-side converter. The Inbox preview pane prefers this so
    /// it doesn't have to do an HTML→MD pass in Swift. Empty for
    /// candidates captured before the cache existed — `stash feeds
    /// reconvert` back-fills them.
    var descriptionMarkdown: String?
    var thumbnailUrl: String?
    var publishedAt: Date?
    var discoveredAt: Date
    var state: String
    var stateChangedAt: Date
    var snoozeUntil: Date?
    var stashedItemId: String?

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return url
    }

    var displayWhen: Date {
        publishedAt ?? discoveredAt
    }
}

enum FeedCandidateState: String {
    case unread
    case stashed
    case dismissed
    case snoozed
}
