import Foundation

/// Provides context-aware template completions for the stash rules script editor.
struct YAMLCompletionProvider {
    /// Returns completion suggestions based on the current line context.
    func completions(for line: String, cursorPosition: Int) -> [String] {
        let prefix = String(line.prefix(cursorPosition))
        
        // Check if the cursor is inside a Go template placeholder like {{. or {{
        if let templateIndex = prefix.range(of: "{{", options: .backwards) {
            let inside = prefix[templateIndex.upperBound...]
            if !inside.contains("}}") {
                let cleanInside = inside.trimmingCharacters(in: .whitespaces)
                let candidates = [
                    ".ID", ".Title", ".URL", ".Domain", ".Type", ".MimeType",
                    ".Sender", ".SenderName", ".SenderEmail", ".SenderDomain",
                    ".Subject", ".Filename", ".Date", ".ExtractedText",
                    ".DuplicateOf", ".DuplicateOfShort", ".Rule.Name"
                ]
                
                if cleanInside.hasPrefix(".") {
                    return candidates.filter { $0.lowercased().hasPrefix(cleanInside.lowercased()) }
                } else if cleanInside.isEmpty {
                    return candidates
                } else {
                    return candidates.filter { $0.dropFirst().lowercased().hasPrefix(cleanInside.lowercased()) }
                }
            }
        }
        
        return []
    }
}
