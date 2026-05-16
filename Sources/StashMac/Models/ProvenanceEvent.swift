import Foundation

/// One row in an item's provenance timeline. Mirrors the Go-side
/// `ProvenanceEvent` returned by `stash provenance <id> --json`.
/// Renders into the ItemDetailView's "Why is this here?" section.
struct ProvenanceEvent: Codable, Identifiable, Hashable {
    var timestamp: Date
    var kind: String      // "capture" | "rule" | "skip" | "tag" | "error"
    var summary: String
    var source: String?
    var rule: String?
    var effects: [String]?
    var tag: String?
    var action: String?   // "add" | "remove" for tag events
    var url: String?
    var domain: String?
    var error: String?

    var id: String {
        "\(timestamp.timeIntervalSince1970)-\(kind)-\(summary)"
    }

    /// SF Symbol mapping for the row badge icon.
    var icon: String {
        switch kind {
        case "capture": return "tray.and.arrow.down"
        case "rule":    return "wand.and.stars"
        case "skip":    return "minus.circle"
        case "tag":     return action == "remove" ? "tag.slash" : "tag"
        case "error":   return "exclamationmark.triangle"
        default:        return "circle"
        }
    }
}
