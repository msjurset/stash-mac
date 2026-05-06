import SwiftUI

// Form-state types shared by RuleDetailView (the inline editor in the
// Rules navigation's detail column). These were previously in a sheet
// view; we kept the struct shapes when migrating to inline editing.

// MARK: - Action row modeling

/// One row in the editor's actions list. A row is bound to a single action
/// type at a time; when the user changes the type via the picker the
/// fields they wrote stay in the row's bag (so they're recoverable if
/// they switch back), but only the type-relevant fields are read on save.
struct ActionRow: Identifiable, Hashable {
    let id = UUID()
    var type: ActionType
    var tagsText: String = ""
    var stringValue: String = ""
    var linkMode: LinkMode = .tag
    var linkTag: String = ""
    var linkID: String = ""

    init(type: ActionType) {
        self.type = type
    }

    /// Split a RuleAction (which can carry multiple effects in one struct)
    /// into one editor row per populated field. Skip rows for empty
    /// strings / nil collections — those weren't really effects.
    static func from(action: RuleAction) -> [ActionRow] {
        var rows: [ActionRow] = []
        if let tags = action.addTags, !tags.isEmpty {
            var r = ActionRow(type: .addTags)
            r.tagsText = tags.joined(separator: ", ")
            rows.append(r)
        }
        if let coll = action.addCollection, !coll.isEmpty {
            var r = ActionRow(type: .addCollection)
            r.stringValue = coll
            rows.append(r)
        }
        if let v = action.setTitle, !v.isEmpty {
            var r = ActionRow(type: .setTitle)
            r.stringValue = v
            rows.append(r)
        }
        if let v = action.setNote, !v.isEmpty {
            var r = ActionRow(type: .setNote)
            r.stringValue = v
            rows.append(r)
        }
        if let v = action.appendNote, !v.isEmpty {
            var r = ActionRow(type: .appendNote)
            r.stringValue = v
            rows.append(r)
        }
        if let v = action.notify, !v.isEmpty {
            var r = ActionRow(type: .notify)
            r.stringValue = v
            rows.append(r)
        }
        if action.skip == true {
            rows.append(ActionRow(type: .skip))
        }
        if let l = action.linkTo {
            var r = ActionRow(type: .linkTo)
            if let tag = l.tag, !tag.isEmpty {
                r.linkMode = .tag
                r.linkTag = tag
            } else if let id = l.id, !id.isEmpty {
                r.linkMode = .id
                r.linkID = id
            }
            rows.append(r)
        }
        return rows
    }

    /// Serialize back to a single-effect RuleAction. Returns nil when the
    /// row's value(s) are empty/blank — empty rows shouldn't generate
    /// no-op entries in the saved YAML.
    func toRuleAction() -> RuleAction? {
        var a = RuleAction()
        switch type {
        case .addTags:
            let tags = tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !tags.isEmpty else { return nil }
            a.addTags = tags
        case .addCollection:
            let v = stringValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            a.addCollection = v
        case .setTitle:
            let v = stringValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            a.setTitle = v
        case .setNote:
            let v = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return nil }
            a.setNote = v
        case .appendNote:
            let v = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return nil }
            a.appendNote = v
        case .notify:
            let v = stringValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            a.notify = v
        case .skip:
            a.skip = true
        case .linkTo:
            switch linkMode {
            case .tag:
                let v = linkTag.trimmingCharacters(in: .whitespaces)
                guard !v.isEmpty else { return nil }
                a.linkTo = RuleLinkSpec(tag: v, id: nil)
            case .id:
                let v = linkID.trimmingCharacters(in: .whitespaces)
                guard !v.isEmpty else { return nil }
                a.linkTo = RuleLinkSpec(tag: nil, id: v)
            }
        }
        return a
    }
}

enum LinkMode: String, Hashable {
    case tag
    case id
}

enum ActionType: String, CaseIterable, Identifiable, Hashable {
    case addTags
    case addCollection
    case setTitle
    case setNote
    case appendNote
    case notify
    case skip
    case linkTo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .addTags:       return "Add Tags"
        case .addCollection: return "Add to Collection"
        case .setTitle:      return "Set Title"
        case .setNote:       return "Set Note"
        case .appendNote:    return "Append Note"
        case .notify:        return "Notify"
        case .skip:          return "Skip"
        case .linkTo:        return "Link To"
        }
    }

    var icon: String {
        switch self {
        case .addTags:       return "tag"
        case .addCollection: return "folder"
        case .setTitle:      return "textformat"
        case .setNote:       return "note.text"
        case .appendNote:    return "plus.bubble"
        case .notify:        return "bell"
        case .skip:          return "xmark.octagon"
        case .linkTo:        return "link"
        }
    }
}

// MARK: - Match condition modeling

/// Editable representation of one match key/value pair. The form keeps an
/// array of these and AND-composes them on save.
struct MatchCondition: Identifiable, Hashable {
    let id = UUID()
    var key: MatchKey
    var value: String

    static var empty: MatchCondition { MatchCondition(key: .domain, value: "") }

    static func from(match: RuleMatch) -> [MatchCondition] {
        var out: [MatchCondition] = []
        if let v = match.type, !v.isEmpty { out.append(.init(key: .type, value: v)) }
        if let v = match.domain, !v.isEmpty { out.append(.init(key: .domain, value: v)) }
        if let v = match.urlRegex, !v.isEmpty { out.append(.init(key: .urlRegex, value: v)) }
        if let v = match.mimeType, !v.isEmpty { out.append(.init(key: .mimeType, value: v)) }
        if let v = match.mimeTypePrefix, !v.isEmpty { out.append(.init(key: .mimeTypePrefix, value: v)) }
        if let v = match.sender, !v.isEmpty { out.append(.init(key: .sender, value: v)) }
        if let v = match.senderDomain, !v.isEmpty { out.append(.init(key: .senderDomain, value: v)) }
        if let v = match.pathGlob, !v.isEmpty { out.append(.init(key: .pathGlob, value: v)) }
        if let v = match.content, !v.isEmpty { out.append(.init(key: .content, value: v)) }
        if let v = match.contentRegex, !v.isEmpty { out.append(.init(key: .contentRegex, value: v)) }
        return out
    }
}

enum MatchKey: String, CaseIterable, Identifiable {
    case type
    case domain
    case urlRegex
    case mimeType
    case mimeTypePrefix
    case sender
    case senderDomain
    case pathGlob
    case content
    case contentRegex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .type:           return "type"
        case .domain:         return "domain"
        case .urlRegex:       return "url_regex"
        case .mimeType:       return "mime_type"
        case .mimeTypePrefix: return "mime_type_prefix"
        case .sender:         return "sender"
        case .senderDomain:   return "sender_domain"
        case .pathGlob:       return "path_glob"
        case .content:        return "content"
        case .contentRegex:   return "content_regex"
        }
    }

    var placeholder: String {
        switch self {
        case .type:           return "url, file, snippet, image, email"
        case .domain:         return "youtube.com"
        case .urlRegex:       return "/watch\\?v="
        case .mimeType:       return "application/pdf"
        case .mimeTypePrefix: return "image/"
        case .sender:         return "alice"
        case .senderDomain:   return "example.com"
        case .pathGlob:       return "*.tax"
        case .content:        return "invoice"
        case .contentRegex:   return "(?i)\\binvoice\\b"
        }
    }
}
