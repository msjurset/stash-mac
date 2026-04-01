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

    var body: some View {
        DetailSection(title: "Extracted Text") {
            VStack(alignment: .leading, spacing: 8) {
                Text(rendered)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if text.count > 500 {
                    Button(isExpanded ? "Show Less" : "Show More") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var rendered: AttributedString {
        if let md = try? AttributedString(markdown: displayText, options: .init(interpretedSyntax: .full)) {
            return md
        }
        return AttributedString(displayText)
    }
}
