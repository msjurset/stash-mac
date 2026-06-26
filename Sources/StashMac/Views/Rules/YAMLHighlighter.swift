import AppKit
import Foundation

/// Applies syntax highlighting to an NSTextStorage.
final class YAMLHighlighter {
    private let keyColor = NSColor.systemBlue
    private let stringColor = NSColor.systemGreen
    private let commentColor = NSColor.systemGray
    private let numberColor = NSColor.systemOrange
    private let boolColor = NSColor.systemPurple
    private let anchorColor = NSColor.systemTeal
    private let templateColor = NSColor.systemPink

    private var baseFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func highlight(_ textStorage: NSTextStorage) {
        let text = textStorage.string
        let fullRange = NSRange(location: 0, length: text.utf16.count)

        // Reset to base style
        textStorage.beginEditing()
        textStorage.addAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)

        let lines = text.components(separatedBy: "\n")
        var offset = 0

        for line in lines {
            let lineRange = NSRange(location: offset, length: line.utf16.count)
            highlightLine(line, in: textStorage, at: lineRange)
            offset += line.utf16.count + 1 // +1 for newline
        }

        textStorage.endEditing()
    }

    private func highlightLine(_ line: String, in storage: NSTextStorage, at lineRange: NSRange) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Comments
        if trimmed.hasPrefix("#") {
            storage.addAttribute(.foregroundColor, value: commentColor, range: lineRange)
            return
        }

        // Inline comments
        if let hashIdx = findInlineComment(in: line) {
            let commentStart = lineRange.location + hashIdx
            let commentLen = lineRange.length - hashIdx
            if commentLen > 0 {
                storage.addAttribute(.foregroundColor, value: commentColor,
                                     range: NSRange(location: commentStart, length: commentLen))
            }
        }

        // Template expressions {{...}}
        highlightPattern("\\{\\{[^}]*\\}\\}", in: line, storage: storage,
                         lineOffset: lineRange.location, color: templateColor)

        // Keys / assignments (word followed by colon or equal)
        if let colonIdx = line.firstIndex(of: ":") {
            let keyPart = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            if !keyPart.isEmpty && !keyPart.hasPrefix("-") {
                if let keyRange = line.range(of: keyPart) {
                    let nsRange = NSRange(keyRange, in: line)
                    let adjusted = NSRange(location: lineRange.location + nsRange.location, length: nsRange.length)
                    storage.addAttribute(.foregroundColor, value: keyColor, range: adjusted)
                }
            }

            // Value after colon
            let afterColon = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            highlightValue(afterColon, in: line, storage: storage, lineOffset: lineRange.location)
        } else if let eqIdx = line.firstIndex(of: "=") {
            let keyPart = String(line[line.startIndex..<eqIdx]).trimmingCharacters(in: .whitespaces)
            if !keyPart.isEmpty {
                if let keyRange = line.range(of: keyPart) {
                    let nsRange = NSRange(keyRange, in: line)
                    let adjusted = NSRange(location: lineRange.location + nsRange.location, length: nsRange.length)
                    storage.addAttribute(.foregroundColor, value: keyColor, range: adjusted)
                }
            }
        }

        // List item dash
        if trimmed.hasPrefix("- ") {
            if let dashRange = line.range(of: "- ") {
                let nsRange = NSRange(dashRange, in: line)
                let adjusted = NSRange(location: lineRange.location + nsRange.location, length: 1)
                storage.addAttribute(.foregroundColor, value: NSColor.systemYellow, range: adjusted)
            }
        }
    }

    private func highlightValue(_ value: String, in line: String, storage: NSTextStorage, lineOffset: Int) {
        guard !value.isEmpty else { return }

        // Find value position in the line
        guard let valueRange = line.range(of: value, options: .backwards) else { return }
        let nsRange = NSRange(valueRange, in: line)
        let adjusted = NSRange(location: lineOffset + nsRange.location, length: nsRange.length)

        // Quoted strings
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            storage.addAttribute(.foregroundColor, value: stringColor, range: adjusted)
            return
        }

        // Booleans
        if ["true", "false", "yes", "no"].contains(value.lowercased()) {
            storage.addAttribute(.foregroundColor, value: boolColor, range: adjusted)
            return
        }

        // Numbers
        if Double(value) != nil {
            storage.addAttribute(.foregroundColor, value: numberColor, range: adjusted)
            return
        }
    }

    private func highlightPattern(_ pattern: String, in line: String, storage: NSTextStorage,
                                   lineOffset: Int, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        for match in matches {
            let adjusted = NSRange(location: lineOffset + match.range.location, length: match.range.length)
            storage.addAttribute(.foregroundColor, value: color, range: adjusted)
        }
    }

    private func findInlineComment(in line: String) -> Int? {
        var inSingleQuote = false
        var inDoubleQuote = false
        for (i, char) in line.enumerated() {
            switch char {
            case "'" where !inDoubleQuote: inSingleQuote.toggle()
            case "\"" where !inSingleQuote: inDoubleQuote.toggle()
            case "#" where !inSingleQuote && !inDoubleQuote:
                if i > 0 && line[line.index(line.startIndex, offsetBy: i - 1)] == " " {
                    return i
                }
            default: break
            }
        }
        return nil
    }
}
