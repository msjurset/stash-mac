import Foundation

/// One slash command that the editor's auto-complete dropdown can
/// match. Modeled as an enum to leave room for future
/// transformation-style commands; today the only commands are
/// "mode" commands that toggle the editor into a typing mode like
/// vim. Templates / typed-character transforms (jrnlbar's `/uc`
/// etc.) are not ported — we'll add them when they prove useful
/// inside stash, not preemptively.
public enum SlashCommand: Identifiable, Hashable, Sendable {
    case mode(ModeCommand)
    case inline(TransformCommand)
    case field(TransformCommand)
    case action(ActionCommand)
    case edit(EditCommand)

    public var name: String {
        switch self {
        case .mode(let m): return m.name
        case .inline(let t): return t.name
        case .field(let t): return t.name
        case .action(let a): return a.name
        case .edit(let e): return e.name
        }
    }

    public var hint: String {
        switch self {
        case .mode(let m): return m.description
        case .inline(let t): return t.description
        case .field(let t): return t.description
        case .action(let a): return a.description
        case .edit(let e): return e.description
        }
    }

    public var id: String { name }
}

/// A toggle-able editor mode. `vim` is the only one wired today;
/// the type stays open so future modes (markdown preview, focus
/// mode, etc.) can register without restructuring.
public struct ModeCommand: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let mode: EditorMode

    public var id: String { name }

    public init(name: String, description: String, mode: EditorMode) {
        self.name = name
        self.description = description
        self.mode = mode
    }
}

/// A command that transforms text content.
public struct TransformCommand: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let transform: @Sendable (String) -> String

    public var id: String { name }

    public init(name: String, description: String, transform: @Sendable @escaping (String) -> String) {
        self.name = name
        self.description = description
        self.transform = transform
    }

    public static func == (lhs: TransformCommand, rhs: TransformCommand) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}


/// A command that performs a contextual edit, receiving the full text and
/// the range of the slash command token, returning the new text and cursor offset.
public struct EditCommand: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let transform: @Sendable (_ text: String, _ tokenRange: Range<String.Index>) -> (newText: String, newCursor: Int)

    public var id: String { name }

    public init(name: String, description: String, transform: @Sendable @escaping (String, Range<String.Index>) -> (String, Int)) {
        self.name = name
        self.description = description
        self.transform = transform
    }

    public static func == (lhs: EditCommand, rhs: EditCommand) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

/// A command that triggers a side-effect (e.g. archiving the item).
public struct ActionCommand: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String

    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// Active editor mode. `.vim` hands the keyboard to VimEngine.
/// `nil` (modeled at the call site) means normal typing.
public enum EditorMode: String, Hashable, Codable, Sendable {
    case vim
    case uppercase
}

/// Built-in slash commands available in every VimHostEditor.
public enum SlashCommandContext: Hashable, Sendable {
    case notes
    case rules
}

public let notesSlashCommands: [SlashCommand] = builtInSlashCommands.filter { cmd in
    switch cmd.name {
    case "tags", "archive": return false // Don't show these in Notes editor
    default: return true
    }
}

public let rulesSlashCommands: [SlashCommand] = builtInSlashCommands.filter { cmd in
    switch cmd.name {
    case "fix", "sum", "tags", "archive": return false // No AI item actions in rules
    default: return true
    }
}

public let builtInSlashCommands: [SlashCommand] = [
    .mode(ModeCommand(name: "vim", description: "vim keybindings", mode: .vim)),
    .mode(ModeCommand(name: "uc", description: "uppercase mode", mode: .uppercase)),

    // Field-level transforms (act on entire text)
    .field(TransformCommand(name: "trim", description: "trim whitespace", transform: { $0.trimmingCharacters(in: .whitespacesAndNewlines) })),
    .field(TransformCommand(name: "sort", description: "sort lines", transform: { text in
        text.components(separatedBy: .newlines)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    })),
    .field(TransformCommand(name: "dedup", description: "deduplicate lines", transform: { text in
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    })),
    
    // Contextual edits
    .edit(EditCommand(name: "dup", description: "duplicate current line", transform: { text, range in
        // Remove the /dup token first
        var mutableText = text
        mutableText.removeSubrange(range)
        
        // Find the line that the token was on
        // range.lowerBound is now the position where the token used to be
        let insertPos = range.lowerBound
        let lineRange = mutableText.lineRange(for: insertPos..<insertPos)
        let lineText = String(mutableText[lineRange])
        
        // If line doesn't have a newline at the end (e.g. last line), we need to add one
        let hasNewline = lineText.hasSuffix("\n") || lineText.hasSuffix("\r\n")
        let newlineStr = hasNewline ? "" : "\n"
        
        // Insert the duplicated line immediately after the current line
        let insertionIndex = lineRange.upperBound
        let textToInsert = newlineStr + lineText
        mutableText.insert(contentsOf: textToInsert, at: insertionIndex)
        
        // Place cursor at the end of the newly duplicated line
        let prefixEnd = mutableText.utf16.distance(from: mutableText.utf16.startIndex, to: insertionIndex.samePosition(in: mutableText.utf16) ?? mutableText.utf16.startIndex)
        let newCursor = prefixEnd + textToInsert.utf16.count
        
        return (mutableText, newCursor)
    })),
    .field(TransformCommand(name: "reverse", description: "reverse text", transform: { String($0.reversed()) })),

    // Inline transforms (replace the /command token)
    .inline(TransformCommand(name: "date", description: "insert current date", transform: { _ in
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    })),
    .inline(TransformCommand(name: "link", description: "insert markdown link", transform: { _ in "[]()" })),
    .inline(TransformCommand(name: "code", description: "insert code block", transform: { _ in "```\n\n```" })),

    .action(ActionCommand(name: "fix", description: "fix spelling/grammar (AI)")),
    .action(ActionCommand(name: "sum", description: "1-sentence summary (AI)")),
    .action(ActionCommand(name: "tags", description: "suggest 3 tags (AI)")),
    .action(ActionCommand(name: "archive", description: "archive this item")),
]

/// Tiny registry that scans the editor's input for `/<word>` and
/// returns matching commands. No external state, no I/O — purely a
/// filter over `builtInSlashCommands`. Lives as a singleton so the
/// editor's textDidChange can hit it without dependency injection.
public final class SlashCommandRegistry: Sendable {

    public static let shared = SlashCommandRegistry()
    public static let notes = SlashCommandRegistry(commands: notesSlashCommands)
    public static let rules = SlashCommandRegistry(commands: rulesSlashCommands)


    private let commands: [SlashCommand]

    public init(commands: [SlashCommand] = builtInSlashCommands) {
        self.commands = commands
    }

    public var all: [SlashCommand] { commands }

    /// Filter the registry by typed prefix. Strips leading slashes;
    /// case-insensitive prefix match. Empty prefix returns everything.
    public func match(prefix: String) -> [SlashCommand] {
        var needle = prefix
        while needle.hasPrefix("/") { needle.removeFirst() }
        let lower = needle.lowercased()
        if lower.isEmpty { return commands }
        return commands.filter { $0.name.lowercased().hasPrefix(lower) }
    }

    /// Exactly one command whose name matches the prefix verbatim
    /// (case-insensitive). Used for the space-trigger commit path.
    public func exactMatch(prefix: String) -> SlashCommand? {
        var needle = prefix
        while needle.hasPrefix("/") { needle.removeFirst() }
        let lower = needle.lowercased()
        return commands.first { $0.name.lowercased() == lower }
    }
}
