import SwiftUI
import AppKit

struct NotesView: View {
    @Environment(StashStore.self) private var store
    @Environment(AIPrefsStore.self) private var aiPrefs
    let text: String
    let itemID: String

    @State private var isExpanded = false
    @State private var showEditor = false
    @State private var editedText = ""
    @State private var originalText = ""
    @State private var editingItemID: String? = nil
    @State private var isFocused = false
    @State private var isShowingAIChat = false
    @State private var aiQuestion = ""
    @FocusState private var isAIChatFocused: Bool
    @State private var mediaDuration: Double? = nil

    private var isTruncated: Bool { text.count > 500 }

    private var displayText: String {
        let baseText = (isTruncated && !isExpanded) ? String(text.prefix(500)) + "..." : text
        
        // Dynamic speaker name replacement
        guard let item = store.items.first(where: { $0.id == itemID })
                ?? store.fetchedItem.flatMap({ $0.id == itemID ? $0 : nil }),
              let map = item.speakerMap, !map.isEmpty else {
            return baseText
        }
        
        var processed = baseText
        // Support #### SPEAKER X and Speaker X: (anywhere in text to catch timeline lists)
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

    var body: some View {
        DetailSection(title: "Notes", showIndicator: store.hasUpdate(itemID)) {
            VStack(alignment: .leading, spacing: 8) {
                VimAwareEditor(
                    itemID: itemID,
                    text: $editedText,
                    onFocusChanged: { focused in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isFocused = focused
                        }
                        if !focused {
                            saveInlineEdit()
                        }
                    },
                    badgePlacement: .topRightOverlay,
                    font: .systemFont(ofSize: 13),
                    textContainerInset: NSSize(width: 10, height: 10),
                    drawsBackground: false,
                    monospaced: false,
                    onDoubleClickWhitespace: openEditor
                )
                .frame(minHeight: isFocused ? 150 : 72, maxHeight: isFocused ? nil : 72)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .onClickOutside {
                    if isFocused {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
                .popover(isPresented: $showEditor, arrowEdge: .top) {
                    editorPopover
                }

                // AI Follow-up Chat
                if aiPrefs.hasKey {
                    HStack(spacing: 8) {
                        // Transcribe button for audio or video items with no transcript
                        if let item = store.items.first(where: { $0.id == itemID })
                            ?? store.fetchedItem.flatMap({ $0.id == itemID ? $0 : nil }),
                           item.type == .file,
                           let mime = item.mimeType, (isAudioMIME(mime) || mime.hasPrefix("video/")),
                           item.extractedText?.isEmpty != false {
                            
                            let isVideo = item.mimeType?.hasPrefix("video/") == true
                            Button {
                                store.transcribeMediaItem(id: itemID, with: aiPrefs, fullVideo: aiPrefs.fullVideoTranscription)
                            } label: {
                                HStack(spacing: 6) {
                                    if store.identifyingItemIDs.contains(itemID) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.6)
                                            .frame(width: 15, height: 15)
                                    } else {
                                        Image(systemName: isVideo ? "video.badge.waveform" : "sparkle")
                                            .font(.system(size: 14, weight: .semibold))
                                            .frame(width: 15, height: 15)
                                    }
                                    Text(store.identifyingItemIDs.contains(itemID) ? (isVideo && aiPrefs.fullVideoTranscription ? "Analyzing..." : "Transcribing...") : (isVideo ? (aiPrefs.fullVideoTranscription ? "Analyze Video" : "Transcribe Video") : "Transcribe with \(aiPrefs.activeProvider.displayName.replacingOccurrences(of: "Google ", with: ""))"))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                            .disabled(store.identifyingItemIDs.contains(itemID))
                            
                            if isVideo {
                                Toggle("Full Video", isOn: Bindable(aiPrefs).fullVideoTranscription)
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if aiPrefs.fullVideoTranscription, let dur = mediaDuration, dur > 30 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "info.circle")
                                        Text("Est. cost: \(estimatedCost(dur))")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Button {
                            if !store.identifyingItemIDs.contains(itemID) {
                                withAnimation(.spring(duration: 0.25)) {
                                    isShowingAIChat.toggle()
                                    if isShowingAIChat {
                                        store.markSeen(itemID)
                                        isAIChatFocused = true
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if store.identifyingItemIDs.contains(itemID) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.6)
                                        .frame(width: 15, height: 15)
                                } else {
                                    Image(systemName: aiPrefs.activeProvider.iconName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(width: 15, height: 15)
                                }

                                if !isShowingAIChat {
                                    Text(store.identifyingItemIDs.contains(itemID) ? "Thinking..." : "Ask \(aiPrefs.activeProvider.displayName.replacingOccurrences(of: "Google ", with: "").replacingOccurrences(of: "Anthropic ", with: ""))")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                            .foregroundStyle(isShowingAIChat ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Ask \(aiPrefs.activeProvider.displayName) a follow-up question")
                        .disabled(store.identifyingItemIDs.contains(itemID))

                        if isShowingAIChat {
                            FilterField(placeholder: "Ask a follow-up...", text: $aiQuestion)
                                .focused($isAIChatFocused)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .onSubmit {
                                    let q = aiQuestion.trimmingCharacters(in: .whitespaces)
                                    guard !q.isEmpty else { return }
                                    store.askAI(id: itemID, question: q)
                                    aiQuestion = ""
                                    isShowingAIChat = false
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                    .padding(.top, text.isEmpty ? 0 : 4)
                }
            }
        }
        .onAppear {
            editedText = text
            originalText = text
        }
        .onChange(of: text) { _, newText in
            if !isFocused {
                editedText = newText
                originalText = newText
            }
        }
        .task(id: itemID) {
            do {
                mediaDuration = await store.getMediaDuration(id: itemID)
            } catch {
                // Task was cancelled, do nothing
            }
        }
        .onChange(of: itemID) { _, _ in
            showEditor = false
            if !isFocused {
                editedText = text
                originalText = text
            }
        }
    }

    private func estimatedCost(_ seconds: Double) -> String {
        let minutes = seconds / 60
        let cost = minutes * 0.0057
        if cost < 0.01 {
            return "< $0.01"
        }
        return String(format: "$%.2f", cost)
    }

    private func saveInlineEdit() {
        let editID = itemID
        let noteToSave = editedText
        let textChanged = editedText != originalText

        if textChanged {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                try? await store.editItem(
                    id: editID,
                    title: nil,
                    note: noteToSave,
                    extractedText: nil,
                    addTags: [],
                    removeTags: [],
                    collection: nil
                )
                originalText = noteToSave
            }
        }
    }

    private func openEditor() {
        originalText = editedText
        editingItemID = itemID
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
            NotesTextEditor(itemID: itemID, text: $editedText, onAction: { action in
                if action.name == "archive" {
                    store.archiveItems(ids: [itemID])
                    showEditor = false
                }
            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            if let editID = editingItemID, editedText != originalText {
                store.editItem(
                    id: editID,
                    title: nil,
                    note: editedText,
                    extractedText: nil,
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

/// Notes editor for the detail pane. Now backed by VimAwareEditor
/// so `/vim` is available — the user can switch to vim keybindings
/// inside the notes editor without leaving the row. Visual config
/// matches the previous NotesTextEditor: monospaced 13pt, 12pt
/// container inset, transparent background.
///
/// Uses `.bottomFooter` for the vim status line — keeps the
/// indicator out of the text body and matches vim's native
/// status-bar placement.
private struct NotesTextEditor: View {
    let itemID: String?
    @Binding var text: String
    var onAction: ((ActionCommand) -> Void)? = nil

    var body: some View {
        VimAwareEditor(
            itemID: itemID,
            text: $text,
            onAction: onAction,
            badgePlacement: .bottomFooter,
            font: .systemFont(ofSize: 13),
            textContainerInset: NSSize(width: 12, height: 12),
            drawsBackground: false,
            monospaced: true
        )
    }
}
