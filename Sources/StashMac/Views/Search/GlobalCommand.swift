import Foundation

public struct GlobalCommand: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let icon: String
    public let action: GlobalAction

    public var id: String { name }

    public init(name: String, description: String, icon: String, action: GlobalAction) {
        self.name = name
        self.description = description
        self.icon = icon
        self.action = action
    }
}

public enum GlobalAction: Sendable {
    case showStats
    case showCheck
    case showLogs
    case showDupes
    case openDataDir
    case backup
    case reindex
    case cleanOrphans
}

public let builtInGlobalCommands: [GlobalCommand] = [
    GlobalCommand(name: "stats", description: "Show library statistics", icon: "chart.bar", action: .showStats),
    GlobalCommand(name: "check", description: "Run health check", icon: "checkmark.shield", action: .showCheck),
    GlobalCommand(name: "logs", description: "View capture logs", icon: "doc.text", action: .showLogs),
    GlobalCommand(name: "dupes", description: "Find duplicate items", icon: "rectangle.on.rectangle", action: .showDupes),
    GlobalCommand(name: "data", description: "Open data directory in Finder", icon: "folder", action: .openDataDir),
    GlobalCommand(name: "backup", description: "Trigger immediate backup", icon: "archivebox", action: .backup),
    GlobalCommand(name: "reindex", description: "Rebuild search index", icon: "arrow.clockwise.circle", action: .reindex),
    GlobalCommand(name: "clean", description: "Delete orphaned files", icon: "trash", action: .cleanOrphans),
]

public final class GlobalCommandRegistry: Sendable {
    public static let shared = GlobalCommandRegistry()
    private let commands: [GlobalCommand]

    public init(commands: [GlobalCommand] = builtInGlobalCommands) {
        self.commands = commands
    }

    public var all: [GlobalCommand] { commands }

    public func match(prefix: String) -> [GlobalCommand] {
        var needle = prefix
        while needle.hasPrefix("/") { needle.removeFirst() }
        let lower = needle.lowercased()
        if lower.isEmpty { return commands }
        return commands.filter { $0.name.lowercased().hasPrefix(lower) }
    }
}
