import SwiftUI
import AppKit

struct ExtractedTextView: View {
    @Environment(StashStore.self) private var store
    let text: String
    let itemID: String
    /// Section heading. Defaults to "Extracted Text" but the
    /// detail view passes "Transcript" for audio items so the UI
    /// matches how the text was actually produced (ASR vs OCR vs
    /// page-content extraction).
    var sectionTitle: String = "Extracted Text"
    /// Title shown in the click-to-edit popover. Mirrors
    /// sectionTitle so the editor heading reads "Edit Transcript"
    /// when the item is audio.
    var editorTitle: String = "Edit Extracted Text"

    @State private var isExpanded = false
    @State private var showEditor = false
    @State private var editedText = ""
    /// Vim controller for the editor popover. Lifted from the
    /// editor's default internal one so the badge / activate
    /// button can render in the popover header instead of
    /// overlaying the text content.
    @State private var popoverVimController = VimModeController()

    private var isTruncated: Bool { text.count > 500 }

    private var displayText: String {
        (isTruncated && !isExpanded) ? String(text.prefix(500)) + "..." : text
    }

    var body: some View {
        DetailSection(title: sectionTitle) {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(displayText, isSelectable: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // NSEvent monitor handles both single- and double-click
                    // *before* AppKit, so selectable text doesn't swallow
                    // them for cursor-positioning or word-selection while
                    // drag-to-select still works.
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

    /// Popout editor. Dismiss (click-off or Escape) saves any change back
    /// to the CLI via `store.editItem`. The popover header carries the
    /// edit-section title on the left, a centered "Click away to save"
    /// hint, and vim controls on the right (one-click `:_` activator
    /// when off; VIM mode badge + cheatsheet when on). Placing them
    /// in the header keeps the editor body unobstructed — the
    /// inline overlay collided with text.
    private var editorPopover: some View {
        VStack(spacing: 0) {
            // Three-column header. ZStack lets us center "Click
            // away to save" against the full width independent of
            // the left title and right controls' sizes — a plain
            // HStack with Spacers would only center between them.
            ZStack {
                Text("Click away to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(editorTitle)
                        .font(.headline)
                    Spacer()
                    VimActivateButton(controller: popoverVimController)
                    VimModeBadge(controller: popoverVimController)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VimAwareEditor(
                itemID: itemID,
                text: $editedText,
                externalController: popoverVimController,                badgePlacement: .external,
                font: .systemFont(ofSize: 13),
                textContainerInset: NSSize(width: 12, height: 12),
                drawsBackground: false,
                monospaced: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            if editedText != text {
                store.editItem(
                    id: itemID,
                    title: nil,
                    note: nil,
                    extractedText: editedText,
                    addTags: [],
                    removeTags: [],
                    collection: nil
                )
            }
        }
    }
}

