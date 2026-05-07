import Foundation

/// One entry in the rules activity log. Mirrors `internal/rules.Event`
/// from gostash. The CLI emits one Event per line in JSONL form via
/// `stash log --json` (or the legacy `stash rules log --json`); the
/// Mac decodes line-by-line.
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
    /// Populated only for `error` events — the original ingest error
    /// message. Optional so older log entries (pre-rename) decode
    /// cleanly.
    var error: String?

    enum EventType: String, Codable, CaseIterable, Hashable {
        case fire
        case skip
        case retro
        case capture
        case error

        var label: String {
            switch self {
            case .fire:    return "fire"
            case .skip:    return "skip"
            case .retro:   return "retro"
            case .capture: return "capture"
            case .error:   return "error"
            }
        }

        var icon: String {
            switch self {
            case .fire:    return "checkmark.circle.fill"
            case .skip:    return "xmark.octagon.fill"
            case .retro:   return "arrow.counterclockwise.circle.fill"
            case .capture: return "tray.and.arrow.down.fill"
            case .error:   return "exclamationmark.triangle.fill"
            }
        }

        /// One-line summary shown above the longer explanation in the
        /// badge popover. Users see this when they click the badge.
        var headline: String {
            switch self {
            case .fire:    return "Rule matched and item saved"
            case .skip:    return "Rule aborted the capture before save"
            case .retro:   return "Retroactive change to an existing item"
            case .capture: return "Item saved with no rule match"
            case .error:   return "Ingest failed before save"
            }
        }

        /// Multi-line explanation in the badge popover. Concrete
        /// enough to clarify what the user is looking at and how it
        /// got logged.
        var explanation: String {
            switch self {
            case .fire:
                return "At least one rule's match conditions held, the rule's actions were applied (tags, collection, title, notes, links, notifications), and the item was saved. The rule list shows every rule that matched."
            case .skip:
                return "A rule with skip: true matched. The capture was aborted before any item was saved — there's no item to open. Use this to filter out spam, low-signal pages, or content you've decided to ignore."
            case .retro:
                return "`stash rules apply` (or `stash-mac` Apply Now) ran rules over already-stashed items and produced a change. Same shape as fire, but capture-time-only effects (skip, notify) don't apply to retro runs."
            case .capture:
                return "An item was successfully saved but no rule matched it. Useful for finding gaps in your rule coverage — patterns of capture events from the same domain or with the same shape are good candidates for a new rule."
            case .error:
                return "An ingest failed before the item could be saved — fetch error, file read error, archive error, etc. The original error message is shown in the row. The item never made it into your library."
            }
        }
    }
}
