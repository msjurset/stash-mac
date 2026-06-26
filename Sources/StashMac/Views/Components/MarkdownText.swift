import SwiftUI

/// Lightweight Markdown renderer. Block-level (headings, lists, tables,
/// rules) is parsed into SwiftUI views; inline (bold, italic, code, links)
/// is handled by `AttributedString(markdown:)`.
///
/// Port of recruit-mac's `MarkdownText` — kept in sync by hand since the
/// project has no external dependencies.
struct MarkdownText: View {
    let content: String
    var lineLimit: Int?
    /// When `false`, the rendered text cannot be selected. Useful when the
    /// text is a preview and the container wants to own click gestures (e.g.
    /// double-click-to-edit) instead of letting AppKit steal them for word
    /// selection.
    var isSelectable: Bool

    init(_ content: String, lineLimit: Int? = nil, isSelectable: Bool = true) {
        self.content = content
        self.lineLimit = lineLimit
        self.isSelectable = isSelectable
    }

    var body: some View {
        Group {
            if lineLimit != nil {
                // Preview mode: inline markdown only, with line limit
                let cleaned = preprocessInline(content)
                if let attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                        .lineLimit(lineLimit)
                        .textSelectionEnabled(isSelectable)
                } else {
                    Text(content)
                        .lineLimit(lineLimit)
                        .textSelectionEnabled(isSelectable)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parseBlocks(content).enumerated()), id: \.offset) { _, block in
                        renderBlock(block)
                    }
                }
            }
        }
    }

    // MARK: - Block parsing


    private enum Block {
        case heading(String, Int)
        case text(String)
        case bullet(String)
        case numberedItem(String, Int)
        case table(headers: [String], rows: [[String]])
        case rule
        case blank
        case code(String, language: String?)
    }

    private func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var currentText: [String] = []
        var i = 0
        var inCodeBlock = false
        var codeBlockContent: [String] = []
        var codeBlockLang: String? = nil

        func flushText() {
            if !currentText.isEmpty {
                blocks.append(.text(currentText.joined(separator: "\n")))
                currentText = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeBlock {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(codeBlockContent.joined(separator: "\n"), language: codeBlockLang))
                    codeBlockContent = []
                    codeBlockLang = nil
                    inCodeBlock = false
                } else {
                    codeBlockContent.append(line)
                }
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushText()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeBlockLang = lang.isEmpty ? nil : String(lang)
                codeBlockContent = []
                inCodeBlock = true
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushText()
                blocks.append(.blank)
                i += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let headingMatch = trimmed.wholeMatch(of: /^(#{1,6})\s+(.+)/) {
                flushText()
                let level = headingMatch.output.1.count
                let text = String(headingMatch.output.2)
                blocks.append(.heading(text, level))
                i += 1
                continue
            }

            if line.contains("|") && i + 1 < lines.count {
                let nextLine = lines[i + 1]
                if nextLine.contains("---") {
                    let isSeparator = nextLine.split(separator: "|").allSatisfy { col in
                        col.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" }
                    }
                    if isSeparator {
                        flushText()
                        let headers = parsePipeRow(line)
                        var rows: [[String]] = []
                        i += 2
                        while i < lines.count && lines[i].contains("|") {
                            let row = parsePipeRow(lines[i])
                            if !row.isEmpty { rows.append(row) }
                            i += 1
                        }
                        blocks.append(.table(headers: headers, rows: rows))
                        continue
                    }
                }
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushText()
                let bulletText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(bulletText))
                i += 1
                continue
            }

            if let dotIndex = trimmed.firstIndex(of: "."),
               trimmed[trimmed.startIndex..<dotIndex].allSatisfy({ $0.isNumber }),
               let num = Int(trimmed[trimmed.startIndex..<dotIndex]) {
                let afterDot = trimmed[trimmed.index(after: dotIndex)...]
                let itemText = afterDot.trimmingCharacters(in: .whitespaces)
                if !itemText.isEmpty {
                    flushText()
                    blocks.append(.numberedItem(itemText, num))
                    i += 1
                    continue
                }
            }

            currentText.append(line)
            i += 1
        }

        if inCodeBlock {
            blocks.append(.code(codeBlockContent.joined(separator: "\n"), language: codeBlockLang))
        } else {
            flushText()
        }
        return blocks
    }

    private func parsePipeRow(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(inlineMarkdown(text))
                .font(level == 1 ? .title3 : level == 2 ? .headline : .subheadline)
                .fontWeight(level <= 2 ? .bold : .semibold)
                .padding(.top, level == 1 ? 8 : 4)
                .textSelectionEnabled(isSelectable)

        case .text(let text):
            let cleaned = preprocessInline(text)
            if let attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
                    .textSelectionEnabled(isSelectable)
            } else {
                Text(text)
                    .textSelectionEnabled(isSelectable)
            }

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .textSelectionEnabled(isSelectable)
            }

        case .numberedItem(let text, let num):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(num).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(inlineMarkdown(text))
                    .textSelectionEnabled(isSelectable)
            }

        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(headers, id: \.self) { header in
                            Text(inlineMarkdown(header))
                                .fontWeight(.semibold)
                                .font(.caption)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                                Text(inlineMarkdown(cell))
                                    .font(.caption)
                                    .gridColumnAlignment(colIdx == 0 ? .leading : .trailing)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

        case .rule:
            Divider()

        case .blank:
            Spacer().frame(height: 4)

        case .code(let code, let language):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .textSelectionEnabled(isSelectable)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Inline helpers

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let cleaned = text.replacing(/^#{1,6}\s+/, with: "")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cleaned)
    }

    private func preprocessInline(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.drop(while: { $0 == " " })
            return !trimmed.hasPrefix("```")
        }.map { line in
            let trimmed = line.drop(while: { $0 == " " })
            if let m = trimmed.wholeMatch(of: /^(#{1,6})\s+(.+)/) {
                return "**\(m.output.2)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "• \(trimmed.dropFirst(2))"
            }
            return String(line)
        }.joined(separator: "\n")
    }
}

extension View {
    /// `.textSelection(.enabled)` and `.textSelection(.disabled)` return
    /// different concrete types, so a plain `condition ? a : b` doesn't
    /// type-check. This wrapper picks the right one at the view-builder level.
    @ViewBuilder
    fileprivate func textSelectionEnabled(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}
