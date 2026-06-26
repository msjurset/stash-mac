import Foundation

/// Mirror of `internal/rules.Rule` from gostash. The JSON shape is fixed
/// by the CLI's `rules list --json` output. `enabled` is optional in the
/// JSON: missing means "enabled" (rules default to on unless `enabled:
/// false` is set in the YAML).
///
/// The decoder uses `.convertFromSnakeCase`, so JSON `add_tags` arrives as
/// `addTags` — bare camelCase property names are correct here.
struct Rule: Codable, Hashable, Identifiable {
    var name: String
    /// Optional human-readable summary. Travels with the rule for
    /// scanability — never validated against the actual match/actions, so
    /// it can drift if the rule changes. Treat as an intent comment.
    var description: String?
    var enabled: Bool?
    var match: RuleMatch
    var actions: [RuleAction]?

    var id: String { name }
    var isEnabled: Bool { enabled ?? true }
}

/// Mirror of `internal/rules.Match`. Every field is optional; whichever
/// fields are set on a given rule are AND-composed by the engine.
struct RuleMatch: Codable, Hashable {
    var type: String?
    var domain: String?
    var urlRegex: String?
    var mimeType: String?
    var mimeTypePrefix: String?
    var sender: String?
    var senderDomain: String?
    var pathGlob: String?
    var content: String?
    var contentRegex: String?
    var hasTag: String?
    var isDuplicate: Bool?

    /// One-line, human-readable summary for the rules list. Mirrors the
    /// shape used by `stash rules list` text output so the Mac UI and CLI
    /// describe rules the same way.
    var summary: String {
        var parts: [String] = []
        if let t = type, !t.isEmpty { parts.append("type=\(t)") }
        if let d = domain, !d.isEmpty { parts.append("domain=\(d)") }
        if let r = urlRegex, !r.isEmpty { parts.append("url_regex=\(r)") }
        if let m = mimeType, !m.isEmpty { parts.append("mime=\(m)") }
        if let m = mimeTypePrefix, !m.isEmpty { parts.append("mime_prefix=\(m)") }
        if let s = sender, !s.isEmpty { parts.append("sender=\(s)") }
        if let s = senderDomain, !s.isEmpty { parts.append("sender_domain=\(s)") }
        if let p = pathGlob, !p.isEmpty { parts.append("path_glob=\(p)") }
        if let c = content, !c.isEmpty { parts.append("content~=\(c)") }
        if let c = contentRegex, !c.isEmpty { parts.append("content_regex=\(c)") }
        if let h = hasTag, !h.isEmpty { parts.append("has_tag=\(h)") }
        if let d = isDuplicate { parts.append("is_duplicate=\(d)") }
        return parts.joined(separator: ", ")
    }
}

/// Mirror of `internal/rules.Action`. Each Action can carry one or more
/// effects; the engine collects effects across the rule's full action list
/// and applies them with the precedence rules described in the gostash
/// docs (tags additive, collection/title/note first-match-wins, etc.).
struct RuleAction: Codable, Hashable {
    var addTags: [String]?
    var addCollection: String?
    var setTitle: String?
    var setNote: String?
    var appendNote: String?
    var skip: Bool?
    var notify: String?
    var linkTo: RuleLinkSpec?
    var exec: String?

    /// Concise badge-summary used by the rules list. Returns one short
    /// phrase per populated effect.
    var badges: [String] {
        var out: [String] = []
        if let tags = addTags, !tags.isEmpty {
            out.append("tags: " + tags.joined(separator: ", "))
        }
        if let coll = addCollection, !coll.isEmpty {
            out.append("→ \(coll)")
        }
        if let t = setTitle, !t.isEmpty {
            out.append("title")
        }
        if let n = setNote, !n.isEmpty {
            out.append("note")
        }
        if let n = appendNote, !n.isEmpty {
            out.append("+note")
        }
        if skip == true {
            out.append("SKIP")
        }
        if let n = notify, !n.isEmpty {
            out.append("notify")
        }
        if let l = linkTo {
            if let tag = l.tag, !tag.isEmpty {
                out.append("link→#\(tag)")
            } else if let id = l.id, !id.isEmpty {
                out.append("link→\(id.prefix(8))")
            }
        }
        if let e = exec, !e.isEmpty {
            out.append("exec")
        }
        return out
    }
}

/// Mirror of `internal/rules.LinkSpec`. Exactly one of tag/id should be set.
struct RuleLinkSpec: Codable, Hashable {
    var tag: String?
    var id: String?
}

/// Result of `stash rules apply --json` — summarizes a retroactive run
/// over existing items. `changes` lists the per-item modifications and is
/// empty when nothing matched.
struct RuleApplySummary: Codable, Hashable {
    var evaluated: Int
    var changed: Int
    var tagsAdded: Int
    var collectionsAdded: Int
    var titlesSet: Int
    var notesUpdated: Int
    var dryRun: Bool
    var changes: [RuleApplyChange]?
}

struct RuleApplyChange: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var addedTags: [String]?
    var addedCollection: String?
    var newTitle: String?
    var noteChanged: Bool?
}

/// Result of `stash rules test --json <id>` — what the rules WOULD do to
/// an existing item without any writes happening.
struct RuleTestResult: Codable, Hashable {
    var itemId: String
    var title: String
    var matchedRules: [String]
    var wouldAddTags: [String]?
    var newTags: [String]?
    var wouldAddCollection: String?
    var wouldSetTitle: String?
    var wouldSetNote: String?
    var wouldAppendNote: String?
    var wouldNotify: [String]?
    var wouldLink: [RuleLinkSpec]?
    var wouldSkip: Bool?
    var skippedBy: String?
    var currentTags: [String]?
    var currentCollections: [String]?
    var errors: [String]?
}
