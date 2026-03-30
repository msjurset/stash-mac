import SwiftUI

struct ExtractedTextView: View {
    let text: String
    @State private var isExpanded = false

    private var displayText: String {
        if text.count > 500 && !isExpanded {
            return String(text.prefix(500)) + "..."
        }
        return text
    }

    private var isMarkdown: Bool {
        // Detect if text contains Markdown formatting
        text.contains("## ") || text.contains("**") || text.contains("- [") ||
        text.contains("](") || text.contains("```") || text.contains("# ")
    }

    var body: some View {
        DetailSection(title: "Extracted Text") {
            VStack(alignment: .leading, spacing: 8) {
                if isMarkdown {
                    Text(markdownAttributed)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(displayText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if text.count > 500 {
                    Button(isExpanded ? "Show Less" : "Show More") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var markdownAttributed: AttributedString {
        (try? AttributedString(markdown: displayText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(displayText)
    }
}
