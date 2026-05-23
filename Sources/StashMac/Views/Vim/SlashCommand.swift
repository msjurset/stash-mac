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

    public var name: String {
        switch self {
        case .mode(let m): return m.name
        case .inline(let t): return t.name
        case .field(let t): return t.name
        case .action(let a): return a.name
        }
    }

    public var hint: String {
        switch self {
        case .mode(let m): return m.description
        case .inline(let t): return t.description
        case .field(let t): return t.description
        case .action(let a): return a.description
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
    .field(TransformCommand(name: "unique", description: "deduplicate lines", transform: { text in
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
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
