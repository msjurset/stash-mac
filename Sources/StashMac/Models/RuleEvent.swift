import Foundation

/// One entry in the rules activity log. Mirrors `internal/rules.Event`
/// from gostash. The CLI emits one Event per line in JSONL form via
/// `stash rules log --json`; the Mac decodes line-by-line.
struct RuleEvent: Codable, Hashable, Identifiable {
    /// Stable per-event identity for SwiftUI's `ForEach` — derived from
    /// timestamp + first rule + title since the log itself doesn't carry
    /// a UUID per event. Collisions are theoretically possible if the
    /// same rule fires on two items with identical titles in the same
    /// nanosecond, but practically irrelevant.
    var id: String {
        "\(timestamp.timeIntervalSinceReferenceDate)|\(rules.first ?? "")|\(title)"
    }

    var timestamp: Date
    var type: EventType
    var rules: [String]
    var itemId: String?
    var title: String
    var source: String
    var effects: [String]?

    enum EventType: String, Codable {
        case fire
        case skip
        case retro

        var label: String {
            switch self {
            case .fire:  return "fire"
            case .skip:  return "skip"
            case .retro: return "retro"
            }
        }

        var icon: String {
            switch self {
            case .fire:  return "checkmark.circle.fill"
            case .skip:  return "xmark.octagon.fill"
            case .retro: return "arrow.counterclockwise.circle.fill"
            }
        }
    }
}
