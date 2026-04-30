import SwiftUI

struct QuickSearchView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StashItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var tagMatches: [StashTag] = []
    @State private var tagActiveIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TagAwareSearchField(
                    query: $query,
                    tagMatches: $tagMatches,
                    onKey: { handleKey($0) }
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
                            commitTag(tag.name)
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
        .onChange(of: query) { _, newQuery in
            recomputeSuggestions()
            if tagMatches.isEmpty {
                debounceSearch(newQuery)
            } else {
                searchTask?.cancel()
                searchTask = nil
                results = []
            }
        }
    }

    // MARK: - Key handling

    private func handleKey(_ key: SuggestKey) -> Bool {
        switch key {
        case .tab, .shiftTab:
            if tagMatches.isEmpty {
                openDropdownIfPossible()
                return true
            }
            if tagMatches.count == 1 {
                tabInsertSingle(tagMatches[0].name)
                return true
            }
            advance(key == .tab ? .down : .up)
            return true
        case .arrowDown, .ctrlJ:
            if tagMatches.isEmpty { return false }
            advance(.down)
            return true
        case .arrowUp, .ctrlK:
            if tagMatches.isEmpty { return false }
            advance(.up)
            return true
        case .enter:
            if !tagMatches.isEmpty {
                let idx = max(tagActiveIndex, 0)
                if idx < tagMatches.count {
                    commitTag(tagMatches[idx].name)
                }
                return true
            }
            // No dropdown — fire the first result if any, else close sheet.
            if let first = results.first {
                store.selectedItemID = first.id
                dismiss()
                return true
            }
            return false
        case .escape:
            if !tagMatches.isEmpty {
                tagMatches = []
                tagActiveIndex = 0
                return true
            }
            if !query.isEmpty {
                query = ""
                return true
            }
            dismiss()
            return true
        }
    }

    private enum Direction { case up, down }

    private func advance(_ direction: Direction) {
        guard !tagMatches.isEmpty else { return }
        switch direction {
        case .down: tagActiveIndex = min(tagActiveIndex + 1, tagMatches.count - 1)
        case .up:   tagActiveIndex = max(tagActiveIndex - 1, 0)
        }
    }

    // MARK: - Tag suggestions

    private func recomputeSuggestions() {
        guard let match = query.range(of: #"(?:^|\s)tag:(\S*)$"#, options: .regularExpression) else {
            tagMatches = []
            tagActiveIndex = 0
            return
        }
        let token = query[match]
        guard let colonIdx = token.firstIndex(of: ":") else {
            tagMatches = []
            tagActiveIndex = 0
            return
        }
        let partial = String(token[token.index(after: colonIdx)...]).lowercased()

        var existing = Set(
            query.matches(of: /tag:(\S+)/).map { String($0.output.1).lowercased() }
        )
        if !partial.isEmpty {
            existing.remove(partial)
        }

        tagMatches = Array(store.tags
            .filter { tag in
                let lower = tag.name.lowercased()
                return (partial.isEmpty || lower.contains(partial)) && !existing.contains(lower)
            }
            .prefix(8))
        tagActiveIndex = 0
    }

    /// Tab-opens-dropdown: if we're already in a `tag:` value context,
    /// `recomputeSuggestions` has it covered. Otherwise treat the trailing
    /// bare word as a key partial and, if it's a prefix of the sole key
    /// (`tag:`), replace it with `tag:` — no trailing space — chaining into
    /// value completion.
    private func openDropdownIfPossible() {
        if query.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) != nil {
            return
        }

        let partial: String
        if let wsIdx = query.lastIndex(where: { $0.isWhitespace }) {
            partial = String(query[query.index(after: wsIdx)...])
        } else {
            partial = query
        }

        let key = "tag:"
        guard key.hasPrefix(partial.lowercased()) else { return }

        let end = query.endIndex
        let start = query.index(end, offsetBy: -partial.count)
        var updated = query
        updated.replaceSubrange(start..<end, with: key)
        query = updated
    }

    private func commitTag(_ tagName: String) {
        guard let range = query.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) else { return }
        let before = query[query.startIndex..<range.lowerBound]
        let prefix = query[range].hasPrefix(" ") ? " " : ""
        query = "\(before)\(prefix)tag:\(tagName) "
        tagMatches = []
        tagActiveIndex = 0
        debounceSearch(query)
    }

    private func tabInsertSingle(_ tagName: String) {
        guard let range = query.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) else { return }
        let before = query[query.startIndex..<range.lowerBound]
        let prefix = query[range].hasPrefix(" ") ? " " : ""
        query = "\(before)\(prefix)tag:\(tagName)"
    }

    /// Parse `tag:xxx` tokens out of the query and pass them as CLI `--tag` flags.
    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            return
        }
        let tagTokens = query.matches(of: /tag:(\S+)/).map { String($0.output.1) }
        let textQuery = query
            .replacing(/tag:\S*/, with: "")
            .trimmingCharacters(in: .whitespaces)

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                let found: [StashItem]
                if textQuery.isEmpty && !tagTokens.isEmpty {
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

/// NSTextField that funnels Tab, Shift-Tab, arrows, Enter, Escape, and
/// Ctrl-J/K through a single `onKey` callback.
struct TagAwareSearchField: NSViewRepresentable {
    @Binding var query: String
    @Binding var tagMatches: [StashTag]
    /// Returns true if the event was consumed.
    let onKey: (SuggestKey) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NoAutoFillTextField()
        field.placeholderString = "Search stash... (tag: to filter)"
        field.isBordered = false
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.font = .preferredFont(forTextStyle: .title3)
        field.focusRingType = .none
        field.delegate = context.coordinator
        context.coordinator.installCtrlJKMonitor(on: field)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != query {
            nsView.stringValue = query
            if let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: nsView.stringValue.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.removeCtrlJKMonitor()
    }

    @MainActor class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagAwareSearchField
        private var eventMonitor: Any?
        private weak var field: NSTextField?

        init(_ parent: TagAwareSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let key: SuggestKey?
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):         key = .tab
            case #selector(NSResponder.insertBacktab(_:)):     key = .shiftTab
            case #selector(NSResponder.moveDown(_:)):          key = .arrowDown
            case #selector(NSResponder.moveUp(_:)):            key = .arrowUp
            case #selector(NSResponder.insertNewline(_:)):     key = .enter
            case #selector(NSResponder.cancelOperation(_:)):   key = .escape
            default: key = nil
            }
            guard let key else { return false }
            return parent.onKey(key)
        }

        func installCtrlJKMonitor(on field: NSTextField) {
            self.field = field
            // Ctrl-J/K don't map to AppKit selectors — intercept via NSEvent.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.modifierFlags.contains(.control) else { return event }
                guard let field = self.field, field.window?.firstResponder is NSTextView else { return event }
                let char = event.charactersIgnoringModifiers
                let key: SuggestKey?
                switch char {
                case "j": key = .ctrlJ
                case "k": key = .ctrlK
                default: key = nil
                }
                guard let key else { return event }
                let consumed = self.parent.onKey(key)
                return consumed ? nil : event
            }
        }

        func removeCtrlJKMonitor() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
    }
}
