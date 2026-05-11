import AppKit
import Foundation
import UniformTypeIdentifiers

/// AppKit panel helpers for the export/import surfaces. Wraps the
/// `NSSavePanel` / `NSOpenPanel` boilerplate so the right-click and
/// menu callers stay focused on the action.
enum ExportPanels {
    /// Show "Save Archive As…" with a context-aware default filename.
    /// Returns the chosen path, or nil if the user cancelled.
    @MainActor
    static func chooseExportDestination(suggestedName: String) -> String? {
        let panel = NSSavePanel()
        panel.title = "Export to Archive"
        panel.allowedContentTypes = [UTType.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Show "Choose Archive…" for an import. Filters to `.zip`.
    @MainActor
    static func chooseImportSource() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Import Archive"
        panel.allowedContentTypes = [UTType.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Build a sensible default filename like
    /// `stash-export-tag-fishing-2026-05-10.zip` for the given scope.
    /// Mirrors the CLI's default-naming convention so an exported
    /// archive looks the same whether the user hit ⌘E or used the CLI.
    static func suggestedFilename(forScopeLabel label: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let stamp = f.string(from: Date())
        let safe = sanitize(label)
        return "stash-export-\(safe)-\(stamp).zip"
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\: \t\n")
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }
        let joined = String(cleaned)
        if joined.count > 60 { return String(joined.prefix(60)) }
        return joined.isEmpty ? "items" : joined
    }
}

