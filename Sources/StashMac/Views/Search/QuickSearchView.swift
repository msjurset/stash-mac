import SwiftUI

struct QuickSearchView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StashItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var tagMatches: [StashTag] = []
    @State private var tagActiveIndex = -1
    @State private var tagJustAccepted = false
    @State private var isNavigating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TagAwareSearchField(
                    query: $query,
                    tagMatches: $tagMatches,
                    tagActiveIndex: $tagActiveIndex,
                    onNavigate: { navigate($0) },
                    onAccept: { handleEnter() }
                )
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding()

            // Tag suggestions
            if !tagMatches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tagMatches.enumerated()), id: \.element.id) { idx, tag in
                        Button {
                            completeTag(tag.name)
                        } label: {
                            HStack {
                                Label("tag:\(tag.name)", systemImage: "tag")
                                    .font(.body)
                                Spacer()
                                if let count = tag.count {
                                    Text("\(count)")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(idx == tagActiveIndex ? Color.accentColor.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            if results.isEmpty && !query.isEmpty && tagMatches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(height: 200)
            } else if tagMatches.isEmpty {
                List(results) { item in
                    Button {
                        store.selectedItemID = item.id
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: item.type.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(item.title)
                                    .lineLimit(1)
                                if let tags = item.tags, !tags.isEmpty {
                                    Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                                        .kerning(0.5)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(item.type.label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(minHeight: 200, maxHeight: 400)
            }
        }
        .frame(width: 500)
        .background(CtrlJKMonitor(onNavigate: { navigate($0) }, tagMatches: $tagMatches))
        .onChange(of: query) { _, newQuery in
            // Skip suggestion rebuild when navigating (preview updates query)
            if isNavigating {
                isNavigating = false
                return
            }
            tagJustAccepted = false
            updateTagSuggestions()
            if tagMatches.isEmpty {
                debounceSearch(newQuery)
            } else {
                // Cancel any in-flight search from previous keystrokes
                searchTask?.cancel()
                searchTask = nil
                results = []
            }
        }
    }

    // MARK: - Navigation

    enum Direction { case down, up }

    /// Single entry point for all suggestion navigation (Tab, arrows, Ctrl-J/K).
    /// Updates the index AND previews the tag in the query field.
    private func navigate(_ direction: Direction) {
        guard !tagMatches.isEmpty else { return }
        switch direction {
        case .down:
            tagActiveIndex = tagActiveIndex < 0 ? 0 : min(tagActiveIndex + 1, tagMatches.count - 1)
        case .up:
            tagActiveIndex = max(tagActiveIndex - 1, 0)
        }
        previewTag(tagMatches[tagActiveIndex].name)
    }

    private func handleEnter() {
        if !tagMatches.isEmpty {
            let idx = tagActiveIndex >= 0 ? tagActiveIndex : 0
            if idx < tagMatches.count {
                completeTag(tagMatches[idx].name)
            }
            tagJustAccepted = true
            return
        }
        if tagJustAccepted {
            tagJustAccepted = false
            return
        }
        if let first = results.first {
            store.selectedItemID = first.id
            dismiss()
        }
    }

    // MARK: - Tag Suggestions

    private func updateTagSuggestions() {
        tagActiveIndex = -1

        guard let match = query.range(of: #"(?:^|\s)tag:(\S*)$"#, options: .regularExpression) else {
            tagMatches = []
            return
        }
        let token = query[match]
        guard let colonIdx = token.firstIndex(of: ":") else {
            tagMatches = []
            return
        }
        let partial = String(token[token.index(after: colonIdx)...]).lowercased()

        let existing = Set(
            query.matches(of: /tag:(\S+)/).compactMap { match -> String? in
                String(match.output.1).lowercased()
            }
        )

        tagMatches = Array(store.tags
            .filter { tag in
                let lower = tag.name.lowercased()
                return (partial.isEmpty || lower.contains(partial)) && !existing.contains(lower)
            }
            .prefix(8))
    }

    /// Preview: replace the partial tag: token with the selected name (no trailing space).
    private func previewTag(_ tagName: String) {
        guard let range = query.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) else { return }
        let before = query[query.startIndex..<range.lowerBound]
        let prefix = query[range].hasPrefix(" ") ? " " : ""
        isNavigating = true
        query = "\(before)\(prefix)tag:\(tagName)"
    }

    /// Commit: replace the partial tag: token and add trailing space, dismiss suggestions.
    private func completeTag(_ tagName: String) {
        guard let range = query.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) else { return }
        let before = query[query.startIndex..<range.lowerBound]
        let prefix = query[range].hasPrefix(" ") ? " " : ""
        query = "\(before)\(prefix)tag:\(tagName) "
        tagMatches = []
        debounceSearch(query)
    }

    /// Parse `tag:xxx` tokens out of the query and pass them as CLI `--tag` flags.
    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            return
        }
        // Extract tag: tokens
        let tagTokens = query.matches(of: /tag:(\S+)/).map { String($0.output.1) }
        // Remaining text query (strip tag: tokens)
        let textQuery = query
            .replacing(/tag:\S*/, with: "")
            .trimmingCharacters(in: .whitespaces)

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                let found: [StashItem]
                if textQuery.isEmpty && !tagTokens.isEmpty {
                    // Tag-only filter — use list with tag flags
                    found = try await StashCLI.shared.listItems(tags: tagTokens, limit: 20)
                } else {
                    found = try await StashCLI.shared.searchItems(query: textQuery, tags: tagTokens, limit: 20)
                }
                if !Task.isCancelled {
                    results = found
                }
            } catch {}
        }
    }
}

// MARK: - TagAwareSearchField

/// NSTextField that forwards Tab, arrows, Enter, and Ctrl-J/K to the parent view's callbacks.
struct TagAwareSearchField: NSViewRepresentable {
    @Binding var query: String
    @Binding var tagMatches: [StashTag]
    @Binding var tagActiveIndex: Int
    let onNavigate: (QuickSearchView.Direction) -> Void
    let onAccept: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search stash... (tag: to filter)"
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .preferredFont(forTextStyle: .title3)
        field.focusRingType = .none
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != query {
            nsView.stringValue = query
            // Place cursor at end after programmatic update
            if let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: nsView.stringValue.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagAwareSearchField

        init(_ parent: TagAwareSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Tab
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if !parent.tagMatches.isEmpty {
                    parent.onNavigate(.down)
                    return true
                }
            }
            // Arrow down
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if !parent.tagMatches.isEmpty {
                    parent.onNavigate(.down)
                    return true
                }
            }
            // Arrow up
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if !parent.tagMatches.isEmpty {
                    parent.onNavigate(.up)
                    return true
                }
            }
            // Enter
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onAccept()
                return true
            }
            return false
        }
    }
}

// MARK: - Ctrl-J/K Event Monitor

/// Intercepts Ctrl-J/K at the NSEvent level (these don't map to standard AppKit commands).
struct CtrlJKMonitor: NSViewRepresentable {
    let onNavigate: (QuickSearchView.Direction) -> Void
    @Binding var tagMatches: [StashTag]

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onNavigate = onNavigate
        view.tagMatchesRef = { [self] in self.tagMatches }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onNavigate = onNavigate
        view.tagMatchesRef = { [self] in self.tagMatches }
    }

    class MonitorView: NSView {
        var onNavigate: ((QuickSearchView.Direction) -> Void)?
        var tagMatchesRef: (() -> [StashTag])?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let tags = self.tagMatchesRef?(), !tags.isEmpty,
                      event.modifierFlags.contains(.control) else { return event }

                let char = event.charactersIgnoringModifiers
                if char == "j" {
                    Task { @MainActor in self.onNavigate?(.down) }
                    return nil
                }
                if char == "k" {
                    Task { @MainActor in self.onNavigate?(.up) }
                    return nil
                }
                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
