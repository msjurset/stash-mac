import SwiftUI
import AppKit

struct NotesView: View {
    @Environment(StashStore.self) private var store
    let text: String
    let itemID: String

    @State private var isExpanded = false
    @State private var showEditor = false
    @State private var editedText = ""

    private var isTruncated: Bool { text.count > 500 }

    private var displayText: String {
        (isTruncated && !isExpanded) ? String(text.prefix(500)) + "..." : text
    }

    var body: some View {
        DetailSection(title: "Notes") {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(displayText, isSelectable: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .background(ClickCatcher(
                        onSingleClick: {
                            if isTruncated {
                                withAnimation { isExpanded.toggle() }
                            }
                        },
                        onDoubleClick: openEditor
                    ))
                    .popover(isPresented: $showEditor, arrowEdge: .top) {
                        editorPopover
                    }

                if isTruncated {
                    Button(isExpanded ? "Show Less" : "Show More") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
    }

    private func openEditor() {
        editedText = text
        showEditor = true
    }

    private var editorPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Notes")
                    .font(.headline)
                Spacer()
                Text("Click away to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            NotesTextEditor(text: $editedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            if editedText != text {
                store.editItem(
                    id: itemID,
                    title: nil,
                    note: editedText,
                    extractedText: nil,
                    addTags: [],
                    removeTags: [],
                    collection: nil
                )
            }
        }
    }
}

private struct NotesTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextEditor
        init(_ parent: NotesTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
