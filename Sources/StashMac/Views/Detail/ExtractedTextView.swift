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
    @State private var originalText = ""
    @State private var editingItemID: String? = nil
    /// Vim controller for the editor popover. Lifted from the
    /// editor's default internal one so the badge / activate
    /// button can render in the popover header instead of
    /// overlaying the text content.
    @State private var popoverVimController = VimModeController()

    private var isTruncated: Bool { text.count > 500 }
    
    /// Hard cap to prevent rendering massive blobs that could hang or crash the UI.
    private let maxRenderLength = 100_000

    private var displayText: String {
        let baseText: String
        if isExpanded {
            baseText = text.count > maxRenderLength 
                ? String(text.prefix(maxRenderLength)) + "\n\n[... truncated for performance ...]"
                : text
        } else {
            baseText = isTruncated ? String(text.prefix(500)) + "..." : text
        }
        
        // Dynamic speaker name replacement
        guard let item = store.items.first(where: { $0.id == itemID }),
              let map = item.speakerMap, !map.isEmpty else {
            return baseText
        }
        
        var processed = baseText
        // Support #### SPEAKER X and Speaker X: (anywhere in text)
        let replacements = [
            (pattern: "#### SPEAKER (\\d+)", template: "#### %@"),
            (pattern: "Speaker\\s+(\\d+):", template: "%@:"),
            (pattern: "\\bSpeaker\\s+(\\d+)\\b", template: "%@")
        ]
        
        for rep in replacements {
            if let regex = try? NSRegularExpression(pattern: rep.pattern, options: [.caseInsensitive]) {
                var offset = 0
                let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
                let matches = regex.matches(in: processed, options: [], range: nsRange)
                
                for match in matches {
                    if match.numberOfRanges > 1,
                       let idRange = Range(match.range(at: 1), in: processed) {
                        let id = String(processed[idRange])
                        if let name = map[id] {
                            let replacement = String(format: rep.template, name.uppercased())
                            let fullNSRange = NSRange(location: match.range.location + offset, length: match.range.length)
                            if let fullRange = Range(fullNSRange, in: processed) {
                                processed.replaceSubrange(fullRange, with: replacement)
                                offset += replacement.count - match.range.length
                            }
                        }
                    }
                }
            }
        }
        
        return processed
    }

    /// Heuristic to detect if the text is likely binary junk (e.g. an MP4 header).
    private var isLikelyBinary: Bool {
        let sample = text.prefix(200)
        let nonPrintableCount = sample.filter {
            guard let scalar = $0.unicodeScalars.first else { return false }
            return !scalar.isASCII && !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.punctuationCharacters.contains(scalar) && !CharacterSet.alphanumerics.contains(scalar)
        }.count
        return nonPrintableCount > 20
    }

    var body: some View {
        DetailSection(title: sectionTitle) {
            VStack(alignment: .leading, spacing: 8) {
                if isLikelyBinary {
                    Label("This section contains non-textual data.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }

                MarkdownText(displayText, isSelectable: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Divider()
                        Button("Clear Extracted Text", role: .destructive) {
                            store.editItem(
                                id: itemID,
                                title: nil,
                                note: nil,
                                extractedText: "",
                                addTags: [],
                                removeTags: [],
                                collection: nil
                            )
                        }
                    }
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
                    HStack(spacing: 12) {
                        Button(isExpanded ? "Show Less" : "Show More") {
                            withAnimation { isExpanded.toggle() }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        
                        if text.count > maxRenderLength && isExpanded {
                            Text("(\(text.count) chars total)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .onChange(of: itemID) { _, _ in
            showEditor = false
        }
    }

    private func openEditor() {
        originalText = text
        editedText = text
        editingItemID = itemID
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
            if let editID = editingItemID, editedText != originalText {
                store.editItem(
                    id: editID,
                    title: nil,
                    note: nil,
                    extractedText: editedText,
                    addTags: [],
                    removeTags: [],
                    collection: nil
                )
            }
            editingItemID = nil
            originalText = ""
        }
    }
}

