import SwiftUI

struct QuickSearchView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StashItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var tagMatches: [StashTag] = []
    @State private var tagActiveIndex = 0
    /// Regex mode: the query is sent through the CLI's `--regex` flag
    /// (RE2, matched against title+notes+url+extracted text) instead
    /// of the FTS-backed positional search. Tag filters still apply
    /// to either; tag-completion suppresses while in regex mode since
    /// `tag:` tokens look like regex literals.
    @State private var regexMode = false
    /// Live status of the regex compile. `nil` = no error or not in
    /// regex mode; otherwise a short message rendered under the
    /// search field so the user knows their pattern won't match.
    @State private var regexError: String?
    /// Cursor inside the results list, driven by ↑/↓ in the search
    /// field. -1 means "no cursor yet" (Enter falls back to the
    /// first row). Reset to 0 whenever results change so the user
    /// can Enter to commit the top hit immediately.
    @State private var resultActiveIndex = -1
    /// Drives the regex-guide popover anchored to the `*` toggle.
    /// Opens whenever regex mode is enabled (toggle click, ⌘R, etc.)
    /// and closes when the user disables regex mode or clicks
    /// outside the popover.
    @State private var regexGuideShown = false

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
                regexToggle
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding()
            if let regexError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(regexError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

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

            if query.isEmpty && tagMatches.isEmpty && results.isEmpty {
                // Initial empty state — no query yet, nothing to show.
                // Without this branch the empty `List` below renders as
                // a 200-tall dark rounded rectangle, which looks like a
                // phantom popup.
                Text("Type to search · use tag: to filter")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if results.isEmpty && !query.isEmpty && tagMatches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(height: 200)
            } else if tagMatches.isEmpty {
                List(Array(results.enumerated()), id: \.element.id) { idx, item in
                    resultRow(idx: idx, item: item)
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
        .onChange(of: regexMode) { _, _ in
            // Toggle re-runs the search so the user sees results
            // change immediately without re-typing the query.
            tagMatches = []
            debounceSearch(query)
        }
        .onChange(of: results) { _, _ in
            // New result set → reset the cursor to the top so Enter
            // commits the highest-relevance hit.
            resultActiveIndex = results.isEmpty ? -1 : 0
        }
    }

    /// Commit a result selection: focus the item, switch nav to All
    /// Items if it's not visible in the current scope (so the row
    /// is highlighted in the list), dismiss the panel.
    private func commitResult(_ item: StashItem) {
        store.selectItemByID(item.id, revealInList: true)
        dismiss()
    }

    /// Single result row. Factored out so the label closure stays
    /// simple enough for Swift's type checker — inlining all the
    /// foreground/background ternaries pushed it past its budget.
    @ViewBuilder
    private func resultRow(idx: Int, item: StashItem) -> some View {
        let active = idx == resultActiveIndex
        let primary: Color = active ? .white : .primary
        let secondary: Color = active ? Color.white.opacity(0.85) : .secondary
        let tertiary: Color = active ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7)
        Button {
            commitResult(item)
        } label: {
            HStack {
                Image(systemName: item.type.icon)
                    .foregroundStyle(secondary)
                    .frame(width: 20)
                VStack(alignment: .leading) {
                    Text(item.title)
                        .lineLimit(1)
                        .foregroundStyle(primary)
                    if let tags = item.tags, !tags.isEmpty {
                        Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                            .kerning(0.5)
                            .font(.caption)
                            .foregroundStyle(secondary)
                    }
                }
                Spacer()
                Text(item.type.label)
                    .font(.caption)
                    .foregroundStyle(tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `*` toggle next to the field. Click toggles regex mode and
    /// pops the RE2 cheatsheet (with negation) when entering regex
    /// mode. Cursor returns to the field after the click so the user
    /// can keep typing without re-grabbing focus. ⌘R also toggles
    /// (bound via a hidden keyboard shortcut button below).
    ///
    /// The popover is hosted by `PersistentPopoverHost` so it stays
    /// open while the user types in the search field — the default
    /// SwiftUI popover is `.transient`, which dismisses on any focus
    /// change.
    private var regexToggle: some View {
        Button {
            toggleRegex()
        } label: {
            Image(systemName: "asterisk")
                .font(.body.weight(.semibold))
                .foregroundStyle(regexMode ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(regexMode ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(regexMode
            ? "Regex search active — click to disable (⌘R)"
            : "Search by RE2 regex pattern — click to enable (⌘R)")
        .background(
            PersistentPopoverHost(
                isPresented: $regexGuideShown,
                preferredEdge: .minY  // anchor below the toggle
            ) {
                RegexGuideView(context: .searchPanel)
            }
        )
        .background(
            // ⌘R toggles regex mode globally while QuickSearch is up.
            // Hidden Button so SwiftUI honors the shortcut without
            // requiring focus on the toggle itself.
            Button("") { toggleRegex() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        )
    }

    /// Flip regex mode and open/close the cheatsheet popover. Returns
    /// first-responder to the search field so typing resumes without
    /// the user clicking back into it. Walk every visible NSWindow
    /// because after toggle the popover may take key status briefly;
    /// we don't filter by isKeyWindow.
    ///
    /// `DispatchQueue.main.async` (twice) defers the focus-return
    /// past both SwiftUI's body re-evaluation AND AppKit's popover
    /// open animation — re-grabbing focus too early loses the race
    /// to the popover, leaving the field unfocused.
    private func toggleRegex() {
        regexMode.toggle()
        regexGuideShown = regexMode
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows where window.isVisible {
                    if let field = findSearchField(in: window.contentView) {
                        window.makeFirstResponder(field)
                        // Position cursor at end of any existing query.
                        if let editor = field.currentEditor() {
                            editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
                        }
                        return
                    }
                }
            }
        }
    }

    /// DFS the view hierarchy for the search field (a
    /// `NoAutoFillTextField` whose placeholder starts with "Search").
    /// Cheap because the panel is small — at most a few dozen views.
    private func findSearchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField,
           (tf.placeholderString ?? "").lowercased().contains("search") {
            return tf
        }
        for sub in view.subviews {
            if let f = findSearchField(in: sub) { return f }
        }
        return nil
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
            if !tagMatches.isEmpty {
                advance(.down)
                return true
            }
            advanceResult(.down)
            return true
        case .arrowUp, .ctrlK:
            if !tagMatches.isEmpty {
                advance(.up)
                return true
            }
            advanceResult(.up)
            return true
        case .enter:
            if !tagMatches.isEmpty {
                let idx = max(tagActiveIndex, 0)
                if idx < tagMatches.count {
                    commitTag(tagMatches[idx].name)
                }
                return true
            }
            // No dropdown — commit the highlighted result, falling
            // back to the first hit when the user hasn't moved the
            // cursor yet.
            let idx = resultActiveIndex >= 0 ? resultActiveIndex : 0
            if idx < results.count {
                commitResult(results[idx])
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

    private func advanceResult(_ direction: Direction) {
        guard !results.isEmpty else { return }
        switch direction {
        case .down:
            resultActiveIndex = min(resultActiveIndex + 1, results.count - 1)
        case .up:
            resultActiveIndex = max(resultActiveIndex - 1, 0)
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
        // Tag completion is meaningless in regex mode — `tag:` may be
        // a literal substring of the user's pattern.
        if regexMode {
            tagMatches = []
            tagActiveIndex = 0
            return
        }
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

    /// Parse `tag:xxx` tokens out of the query and pass them as CLI
    /// `--tag` flags. In regex mode the remainder of the query is the
    /// RE2 pattern; in free-text mode it's the FTS query. Tag tokens
    /// apply in either mode so the user can scope a regex by tag.
    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            regexError = nil
            return
        }
        // Tag tokens are only honored in non-regex mode — treating
        // `tag:` as a tag filter inside an arbitrary regex would
        // mangle patterns the user actually meant to match (e.g.
        // "tag:.+" intending "literal `tag:` then anything").
        let tagTokens: [String]
        let textQuery: String
        if regexMode {
            tagTokens = []
            textQuery = query
        } else {
            tagTokens = query.matches(of: /tag:(\S+)/).map { String($0.output.1) }
            textQuery = query
                .replacing(/tag:\S*/, with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        // Pre-validate the regex client-side so the user gets fast
        // feedback on syntax errors instead of an empty result list.
        // RE2 and NSRegularExpression don't have identical syntax but
        // the common subset (anchors, groups, character classes,
        // alternation, quantifiers) covers virtually every practical
        // pattern; edge-case mismatches will still show up as
        // "no results" rather than an inline error.
        if regexMode {
            if (try? NSRegularExpression(pattern: textQuery)) == nil {
                regexError = "Invalid regex pattern"
                results = []
                return
            }
            regexError = nil
        } else {
            regexError = nil
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                let found: [StashItem]
                if regexMode {
                    found = try await StashCLI.shared.searchItems(
                        query: "",
                        limit: 50,
                        regex: textQuery
                    )
                } else if textQuery.isEmpty && !tagTokens.isEmpty {
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
        // Layer-5 interceptor wiring is handled by
        // NoAutoFillTextField.viewDidMoveToWindow itself — no per
        // call-site install or DispatchQueue.main.async race needed.
        // We just need to focus the field once SwiftUI has attached
        // it to the sheet's window.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
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
