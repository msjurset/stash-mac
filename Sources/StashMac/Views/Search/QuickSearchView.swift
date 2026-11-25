import AppKit
import SwiftUI

private let globalStashFieldTags = [
    "tag", "!tag", "collection", "type", "is", "view", "action"
]

struct QuickSearchView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var onDismiss: (() -> Void)? = nil

    @State private var query = ""
    @State private var results: [StashItem] = []
    @State private var matches: [SearchResult] = []
    @State private var activeIndex = 0

    @State private var searchFieldFocusTrigger = 0
    @State private var pendingCursor: Int? = nil
    @State private var cursorLocation: Int = 0
    @State private var lastSetQuery: String? = nil

    @State private var searchTask: Task<Void, Never>?
    @State private var regexMode = false
    @State private var regexError: String?
    @State private var regexGuideShown = false
    @State private var phoneHandoffShown = false
    @State private var searchError: String?

    @State private var browseMode: BrowseMode = BrowseMode.load()
    @State private var history: [SearchHistoryEntry] = []

    struct Suggestion: Identifiable, Equatable {
        let id: String
        let label: String
        let display: String
        let subtitle: String?
        let icon: String
        let count: Int
        let command: GlobalCommand?

        static func == (lhs: Suggestion, rhs: Suggestion) -> Bool {
            lhs.id == rhs.id && lhs.label == rhs.label && lhs.count == rhs.count
        }
    }

    @State private var suggestions: [Suggestion] = []
    @State private var suggestionIndex: Int = -1
    @State private var dismissedSuggestionsQuery: String? = nil
    @State private var isResultsFocused: Bool = false
    @State private var hadSuggestionsBeforeResultsFocus: Bool = false

    private let commandRegistry = GlobalCommandRegistry.shared

    enum BrowseMode: String, CaseIterable, Identifiable {
        case recent, frequent
        var id: String { rawValue }
        var label: String { self == .recent ? "Recent" : "Frequent" }
        static func load() -> BrowseMode {
            BrowseMode(rawValue: UserDefaults.standard.string(forKey: "QuickSearchBrowseMode") ?? "recent")
                ?? .recent
        }
        func save() {
            UserDefaults.standard.set(rawValue, forKey: "QuickSearchBrowseMode")
        }
    }

    enum ResultPayload {
        case item(StashItem)
        case history(SearchHistoryEntry)
        case view(NavigationItem)
        case action
        case filter(String)
    }

    struct SearchResult: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let typeBadge: String
        let systemImage: String
        let payload: ResultPayload
        let action: () -> Void
    }

    private func closePanel() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                FilterField(
                    placeholder: regexMode
                        ? "Regex search across stash... /pattern/ (! to negate)"
                        : "Search stash, views, actions... (Tab/Enter for chips: tag: collection: type: is: /cmd)",
                    text: $query,
                    font: .preferredFont(forTextStyle: .title3),
                    autoFocus: true,
                    focusTrigger: searchFieldFocusTrigger,
                    pendingCursor: $pendingCursor,
                    onSelectionChanged: { loc in
                        cursorLocation = loc
                        if !isResultsFocused {
                            updateSuggestions()
                        }
                    },
                    onKey: { handleKey($0) },
                    onBeginEditing: {
                        if !isResultsFocused {
                            updateSuggestions()
                        }
                    }
                )
                .frame(height: 28)

                if let regexError {
                    Text(regexError)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }

                regexToggle

                if !query.isEmpty {
                    Button {
                        query = ""
                        suggestions = []
                        suggestionIndex = -1
                        regexError = nil
                        searchError = nil
                        cursorLocation = 0
                        searchFieldFocusTrigger &+= 1
                        rebuildMatches()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .pointingHandCursor()
                    .help("Clear search")
                }

                Button("Esc") { closePanel() }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)
                    .focusable(false)
                    .pointingHandCursor()
                    .help("Close Global Search (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let searchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(searchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Interactive filter & scope chips bar
            if !regexMode {
                globalSearchChipsBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // Unified autocomplete dropdown
            if !suggestions.isEmpty {
                Divider()
                let visibleCount = min(suggestions.count, 8)
                let rowHeight: CGFloat = 28
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(query.hasPrefix("/") ? "Global Commands" : "Autocomplete Filter Chip")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Tab / ↑↓ to cycle • Enter to insert • ⌃Tab / ⌥Tab to focus results • Esc to dismiss")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, suggestion in
                                    Button {
                                        acceptSuggestion(suggestion)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: suggestion.icon)
                                                .foregroundStyle(idx == suggestionIndex ? Color.accentColor : .secondary)
                                                .frame(width: 16)
                                            Text(suggestion.display)
                                                .font(.callout.weight(idx == suggestionIndex ? .semibold : .regular))
                                            if let sub = suggestion.subtitle {
                                                Text(sub)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            if suggestion.count > 0 {
                                                Text("\(suggestion.count)")
                                                    .foregroundStyle(.tertiary)
                                                    .font(.caption)
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 4)
                                        .frame(height: rowHeight)
                                        .background(idx == suggestionIndex ? Color.accentColor.opacity(0.2) : .clear)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .focusable(false)
                                    .pointingHandCursor()
                                    .id(idx)
                                }
                            }
                        }
                        .frame(height: CGFloat(visibleCount) * rowHeight)
                        .onChange(of: suggestionIndex) { _, newIdx in
                            guard newIdx >= 0 && newIdx < suggestions.count else { return }
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(newIdx, anchor: .center)
                            }
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.65))
            }

            Divider()

            // Main Split Area: Results List (Left) + Live Preview Pane (Right)
            if !matches.isEmpty {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                resultsHeaderBar
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)

                                ForEach(Array(matches.enumerated()), id: \.element.id) { idx, match in
                                    resultRow(idx: idx, match: match)
                                        .id(match.id)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: activeIndex) { _, newIdx in
                            phoneHandoffShown = false
                            withAnimation(.easeOut(duration: 0.12)) {
                                if newIdx >= 0 && newIdx < matches.count {
                                    proxy.scrollTo(matches[newIdx].id, anchor: .center)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if activeIndex >= 0 && activeIndex < matches.count {
                        Divider()
                        previewPane(for: matches[activeIndex])
                            .frame(width: 360)
                            .frame(maxHeight: .infinity)
                            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: regexError != nil ? "exclamationmark.triangle" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(regexError != nil ? "Fix the regular expression above to see matches." : "No matching items, views, or actions.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity, alignment: .top)
        .onAppear {
            rebuildMatches()
        }
        .task {
            await reloadHistory()
            rebuildMatches()
        }
        .onChange(of: browseMode) { _, mode in
            mode.save()
            Task {
                await reloadHistory()
                rebuildMatches()
            }
        }
        .onChange(of: store.globalSearchTick) { _, _ in
            searchFieldFocusTrigger &+= 1
            Task {
                await reloadHistory()
                rebuildMatches()
            }
        }
        .onChange(of: query) { _, newQuery in
            isResultsFocused = false
            if newQuery == "//" && !regexMode {
                regexMode = true
                regexGuideShown = true
                suggestions = []
                suggestionIndex = -1
                pendingCursor = 1
                cursorLocation = 1
                debounceSearch(newQuery)
                return
            }

            dismissedSuggestionsQuery = nil

            if let last = lastSetQuery, last == newQuery {
                lastSetQuery = nil
                debounceSearch(newQuery)
                return
            }
            lastSetQuery = nil
            updateSuggestions()
            debounceSearch(newQuery)
        }
        .onChange(of: regexMode) { _, _ in
            suggestions = []
            suggestionIndex = -1
            debounceSearch(query)
        }
        .onChange(of: results) { _, _ in
            rebuildMatches()
        }
    }

    // MARK: - Results Header & Browse Mode Toggle

    @ViewBuilder
    private var resultsHeaderBar: some View {
        let isEmptyQuery = query.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 8) {
            Text(isEmptyQuery ? "Recent, Saved Searches & Actions" : "Results (\(matches.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isResultsFocused ? Color.accentColor : .secondary)
            if isResultsFocused {
                Text("Focused")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if isEmptyQuery && !isResultsFocused {
                HStack(spacing: 4) {
                    browseToggleButton(mode: .recent, icon: "clock", tooltip: "Recent searches first")
                    browseToggleButton(mode: .frequent, icon: "chart.bar", tooltip: "Frequent searches first")
                }
            } else if isResultsFocused {
                Text("Tab / ↑↓ to navigate • Enter to open • ⌃Tab / ⌥Tab or Esc for search bar")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if suggestions.isEmpty {
                Text("↑↓ or ⌃Tab / ⌥Tab to navigate • Enter to open")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("⌃Tab / ⌥Tab to focus results")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func browseToggleButton(mode: BrowseMode, icon: String, tooltip: String) -> some View {
        let active = (browseMode == mode)
        return Button {
            browseMode = mode
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(mode.label)
                    .font(.caption2.weight(active ? .semibold : .regular))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointingHandCursor()
        .help(tooltip)
    }

    // MARK: - Dynamic Chips Bar

    private struct ChipItem: Identifiable {
        let id: String
        let token: String
        let label: String
        let icon: String
        let isActive: Bool
    }

    private var globalSearchChipsBar: some View {
        let knownSet = Set(["tag", "t", "collection", "col", "c", "type", "is", "view", "v", "action", "a"])
        let activeTokens = SearchTokenHelper.extractStructuredTokens(from: query, knownKeys: knownSet)
        let activeSet = Set(activeTokens.map { SearchTokenHelper.normalizeChip($0) })

        var chips: [ChipItem] = []
        var seen = Set<String>()

        func addChip(token: String, label: String, icon: String, active: Bool) {
            let norm = SearchTokenHelper.normalizeChip(token)
            guard !seen.contains(norm) else { return }
            seen.insert(norm)
            chips.append(ChipItem(id: norm, token: token, label: label, icon: icon, isActive: active))
        }

        // 1. Active structured tokens first so the user can see & click to remove them
        for tok in activeTokens {
            let keyPart = tok.split(separator: ":").first.map(String.init) ?? tok
            let displayLabel = tok.replacingOccurrences(of: "\"", with: "")
            addChip(
                token: tok,
                label: displayLabel,
                icon: iconForTag("\(keyPart):"),
                active: true
            )
        }

        // 2. Scope & high-frequency filter chips
        let presets: [(token: String, label: String, icon: String)] = [
            ("type:url", "URLs", "globe"),
            ("type:snippet", "Snippets", "doc.text"),
            ("type:image", "Images", "photo"),
            ("type:file", "Files", "doc"),
            ("type:audio", "Audio", "waveform"),
            ("type:email", "Emails", "envelope"),
            ("is:recipe", "Recipes", "fork.knife"),
            ("is:unread", "Unread", "circle.fill"),
            ("is:located", "Geotagged", "mappin.and.ellipse"),
            ("type:view", "Views", "sidebar.left"),
            ("type:action", "Actions", "bolt.fill")
        ]
        for p in presets {
            let isAct = activeSet.contains(SearchTokenHelper.normalizeChip(p.token))
            addChip(token: p.token, label: p.label, icon: p.icon, active: isAct)
        }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    Button {
                        toggleChipToken(chip.token)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: chip.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(chip.label)
                                .font(.caption.weight(chip.isActive ? .semibold : .regular))
                                .lineLimit(1)
                            if chip.isActive {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.leading, 1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(chip.isActive ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(chip.isActive ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .foregroundStyle(chip.isActive ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .pointingHandCursor()
                }
            }
        }
    }

    private func toggleChipToken(_ token: String) {
        let updated = SearchTokenHelper.toggleChip(token, in: query)
        let finalQuery = updated.isEmpty ? "" : (updated.hasSuffix(" ") ? updated : updated + " ")
        lastSetQuery = finalQuery
        query = finalQuery
        suggestions = []
        suggestionIndex = -1
        pendingCursor = finalQuery.count
        cursorLocation = finalQuery.count
        searchFieldFocusTrigger &+= 1
        debounceSearch(finalQuery)
    }

    // MARK: - Regex Toggle

    private var regexToggle: some View {
        Button {
            toggleRegex()
        } label: {
            Image(systemName: "asterisk")
                .font(.body.weight(.semibold))
                .foregroundStyle(regexMode ? Color.white : Color.secondary)
                .frame(width: 24, height: 24)
                .background(regexMode ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointingHandCursor()
        .help(regexMode
            ? "Regex search active — click to disable (⌘R)"
            : "Search by RE2 regex pattern — click to enable (⌘R or type //)")
        .background(
            PersistentPopoverHost(
                isPresented: $regexGuideShown,
                preferredEdge: .minY
            ) {
                RegexGuideView(context: .searchPanel)
            }
        )
        .background(
            Button("") { toggleRegex() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { triggerPhoneHandoffForActiveMatch() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .hidden()
        )
    }

    private func triggerPhoneHandoffForActiveMatch() {
        guard activeIndex >= 0 && activeIndex < matches.count else { return }
        if case .item = matches[activeIndex].payload {
            phoneHandoffShown.toggle()
        }
    }

    private func toggleRegex() {
        regexMode.toggle()
        regexGuideShown = regexMode
        if regexMode {
            suggestions = []
            suggestionIndex = -1
        } else {
            regexError = nil
            updateSuggestions()
        }
        searchFieldFocusTrigger &+= 1
    }

    // MARK: - Key Handling

    private func toggleResultsFocus() {
        if isResultsFocused {
            isResultsFocused = false
            dismissedSuggestionsQuery = nil
            pendingCursor = query.count
            cursorLocation = query.count
            searchFieldFocusTrigger &+= 1
            if !regexMode {
                _ = requestSuggestions()
            }
        } else {
            hadSuggestionsBeforeResultsFocus = !suggestions.isEmpty
            suggestions = []
            suggestionIndex = -1
            dismissedSuggestionsQuery = query
            rebuildMatches()
            if !matches.isEmpty {
                isResultsFocused = true
                if activeIndex < 0 || activeIndex >= matches.count {
                    activeIndex = 0
                }
            }
        }
    }

    private func handleKey(_ key: SuggestKey) -> Bool {
        switch key {
        case .toggleResultsFocus:
            toggleResultsFocus()
            return true
        case .tab:
            handleTab(shift: false)
            return true
        case .shiftTab:
            handleTab(shift: true)
            return true
        case .arrowDown, .ctrlJ:
            handleDownArrow()
            return true
        case .arrowUp, .ctrlK:
            handleUpArrow()
            return true
        case .enter:
            handleEnter()
            return true
        case .escape:
            if phoneHandoffShown {
                phoneHandoffShown = false
                return true
            }
            if regexGuideShown {
                regexGuideShown = false
                return true
            }
            if isResultsFocused {
                isResultsFocused = false
                dismissedSuggestionsQuery = nil
                pendingCursor = query.count
                cursorLocation = query.count
                searchFieldFocusTrigger &+= 1
                if hadSuggestionsBeforeResultsFocus {
                    hadSuggestionsBeforeResultsFocus = false
                    _ = requestSuggestions()
                } else {
                    updateSuggestions()
                }
                return true
            }
            if !suggestions.isEmpty {
                suggestions = []
                suggestionIndex = -1
                dismissedSuggestionsQuery = query
                return true
            }
            if !query.isEmpty || regexMode {
                query = ""
                cursorLocation = 0
                regexMode = false
                regexError = nil
                searchError = nil
                rebuildMatches()
                return true
            }
            closePanel()
            return true
        }
    }

    private func handleUpArrow() {
        if !isResultsFocused && !suggestions.isEmpty {
            if suggestionIndex > 0 {
                suggestionIndex -= 1
            } else {
                suggestionIndex = suggestions.count - 1
            }
        } else if activeIndex > 0 {
            activeIndex -= 1
        } else if !matches.isEmpty {
            activeIndex = matches.count - 1
        }
    }

    private func handleDownArrow() {
        if !isResultsFocused && !suggestions.isEmpty {
            if suggestionIndex < suggestions.count - 1 {
                suggestionIndex += 1
            } else {
                suggestionIndex = 0
            }
        } else if activeIndex < matches.count - 1 {
            activeIndex += 1
        } else if !matches.isEmpty {
            activeIndex = 0
        }
    }

    private func handleTab(shift: Bool) {
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
        if (flags.contains(.control) || flags.contains(.option)) && !flags.contains(.command) {
            toggleResultsFocus()
            return
        }

        if isResultsFocused {
            if shift {
                handleUpArrow()
            } else {
                handleDownArrow()
            }
            return
        }

        if !suggestions.isEmpty {
            if !shift && suggestions.count == 1 {
                acceptSuggestion(suggestions[0])
                return
            }
            if shift {
                handleUpArrow()
            } else {
                handleDownArrow()
            }
            return
        }

        if !regexMode && dismissedSuggestionsQuery != query {
            if requestSuggestions() {
                if shift {
                    suggestionIndex = max(0, suggestions.count - 1)
                }
                return
            }
        }

        if shift {
            handleUpArrow()
        } else {
            handleDownArrow()
        }
    }

    private func handleEnter() {
        if !isResultsFocused && !suggestions.isEmpty && suggestionIndex >= 0 && suggestionIndex < suggestions.count {
            acceptSuggestion(suggestions[suggestionIndex])
            return
        }
        commitSelectedMatch()
    }

    private func acceptSuggestion(_ suggestion: Suggestion) {
        if let cmd = suggestion.command {
            if cmd.action == .sendToPhone {
                suggestions = []
                suggestionIndex = -1
                query = ""
                cursorLocation = 0
                rebuildMatches()
                if activeIndex >= 0 && activeIndex < matches.count,
                   case .item = matches[activeIndex].payload {
                    phoneHandoffShown = true
                    return
                }
            }
            store.handleGlobalAction(cmd.action)
            closePanel()
            return
        }
        completeSuggestion(suggestion.label)
    }

    // MARK: - Token Autocomplete Engine

    private func tokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex && text[i].isWhitespace {
                i = text.index(after: i)
            }
            if i >= text.endIndex { break }
            let start = i
            var inQuotes = false
            while i < text.endIndex {
                let c = text[i]
                if c == "\"" { inQuotes.toggle() }
                else if c.isWhitespace && !inQuotes { break }
                i = text.index(after: i)
            }
            ranges.append(start..<i)
        }
        return ranges
    }

    private func canonicalTagName(_ raw: String) -> String {
        switch raw {
        case "t", "tags": return "tag"
        case "-tag", "^tag", "!t": return "!tag"
        case "col", "c", "collections", "folder": return "collection"
        case "v", "views", "nav": return "view"
        case "a", "actions", "cmd": return "action"
        default: return raw
        }
    }

    private func parseToken(at location: Int, in text: String) -> (tag: String?, partial: String, range: Range<String.Index>)? {
        let clampedOffset = max(0, min(location, text.count))
        let cursorIndex = text.index(text.startIndex, offsetBy: clampedOffset)
        let ranges = tokenRanges(in: text)

        var activeRange: Range<String.Index>? = nil
        for r in ranges {
            if r.lowerBound <= cursorIndex && cursorIndex <= r.upperBound {
                activeRange = r
                break
            }
        }

        let tokenRange = activeRange ?? (cursorIndex..<cursorIndex)
        let token = String(text[tokenRange])

        if let colonIdx = token.firstIndex(of: ":") {
            let rawTag = String(token[token.startIndex..<colonIdx]).lowercased()
            let canonicalTag = canonicalTagName(rawTag)
            var partial = String(token[token.index(after: colonIdx)...]).lowercased()
            if partial.hasPrefix("\"") { partial.removeFirst() }
            if partial.hasSuffix("\"") { partial.removeLast() }
            if globalStashFieldTags.contains(canonicalTag) {
                return (canonicalTag, partial, tokenRange)
            }
        }

        var unquoted = token.lowercased()
        if unquoted.hasPrefix("\"") { unquoted.removeFirst() }
        if unquoted.hasSuffix("\"") { unquoted.removeLast() }
        return (nil, unquoted, tokenRange)
    }

    private func usedSingleValueKeys(in text: String) -> Set<String> {
        var used = Set<String>()
        let multiAllowed: Set<String> = ["tag", "!tag", "is"]
        for r in tokenRanges(in: text) {
            let token = text[r]
            if let colon = token.firstIndex(of: ":") {
                let rawKey = String(token[token.startIndex..<colon]).lowercased()
                let key = canonicalTagName(rawKey)
                if globalStashFieldTags.contains(key) && !multiAllowed.contains(key) {
                    used.insert(key)
                }
            }
        }
        return used
    }

    private func showAllUnusedKeys(in text: String, partial: String = "") {
        let used = usedSingleValueKeys(in: text)
        let matchingKeys = globalStashFieldTags.filter {
            !used.contains($0) && (partial.isEmpty || ($0.hasPrefix(partial) && $0 != partial))
        }
        suggestions = matchingKeys.map { key in
            Suggestion(
                id: "key:\(key)",
                label: "\(key):",
                display: "\(key):",
                subtitle: tagDescription(key),
                icon: iconForTag("\(key):"),
                count: 0,
                command: nil
            )
        }
        suggestionIndex = suggestions.isEmpty ? -1 : 0
    }

    @discardableResult
    private func requestSuggestions() -> Bool {
        if regexMode { return false }
        if query.hasPrefix("/") && !query.contains(" ") {
            populateCommandSuggestions(prefix: query)
            return !suggestions.isEmpty
        }

        let effectiveCursor = max(0, min(cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else {
            showAllUnusedKeys(in: query)
            return !suggestions.isEmpty
        }

        if let tag = parsed.tag {
            populateTagValues(tag, partial: parsed.partial)
            return !suggestions.isEmpty
        } else {
            showAllUnusedKeys(in: query, partial: parsed.partial)
            return !suggestions.isEmpty
        }
    }

    private func updateSuggestions() {
        if regexMode {
            suggestions = []
            suggestionIndex = -1
            return
        }

        if query.hasPrefix("/") && !query.contains(" ") {
            populateCommandSuggestions(prefix: query)
            return
        }

        let effectiveCursor = max(0, min(cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else {
            suggestions = []
            suggestionIndex = -1
            return
        }

        if let tag = parsed.tag {
            populateTagValues(tag, partial: parsed.partial)
            return
        }

        if !parsed.partial.isEmpty {
            showAllUnusedKeys(in: query, partial: parsed.partial)
            return
        }

        suggestions = []
        suggestionIndex = -1
    }

    private func populateCommandSuggestions(prefix: String) {
        let cmds = commandRegistry.match(prefix: prefix)
        suggestions = cmds.map { cmd in
            Suggestion(
                id: "cmd:\(cmd.name)",
                label: "/\(cmd.name)",
                display: "/\(cmd.name)",
                subtitle: cmd.description,
                icon: cmd.icon,
                count: 0,
                command: cmd
            )
        }
        suggestionIndex = suggestions.isEmpty ? -1 : 0
    }

    private func tagDescription(_ key: String) -> String {
        switch key {
        case "tag": return "Filter items by tag"
        case "!tag": return "Exclude items with tag"
        case "collection": return "Scope search to a collection or smart collection"
        case "type": return "Filter by item type (url, snippet, image, file, audio, email, view, action)"
        case "is": return "Filter by status (recipe, unread, starred, located, annotated, archived)"
        case "view": return "Jump to a Stash sidebar view"
        case "action": return "Run a Stash quick action or command"
        default: return ""
        }
    }

    private func populateTagValues(_ tag: String, partial: String) {
        struct Candidate {
            let key: String
            let display: String
            let subtitle: String?
            let icon: String
            let count: Int
        }
        var candidates: [Candidate] = []

        switch tag {
        case "tag", "!tag":
            let existing = Set(
                tokenRanges(in: query).compactMap { r -> String? in
                    let tok = String(query[r])
                    guard let colon = tok.firstIndex(of: ":") else { return nil }
                    let k = canonicalTagName(String(tok[..<colon]).lowercased())
                    guard k == "tag" || k == "!tag" else { return nil }
                    let v = String(tok[tok.index(after: colon)...]).replacingOccurrences(of: "\"", with: "").lowercased()
                    return v == partial ? nil : v
                }
            )
            candidates = store.tags
                .filter { !existing.contains($0.name.lowercased()) }
                .map { t in
                    Candidate(
                        key: t.name,
                        display: t.name,
                        subtitle: nil,
                        icon: tag == "!tag" ? "tag.slash" : "tag",
                        count: t.count ?? 0
                    )
                }

        case "collection":
            for col in store.collections {
                candidates.append(Candidate(
                    key: col.name,
                    display: col.name,
                    subtitle: col.description ?? "Collection",
                    icon: "folder",
                    count: 0
                ))
            }

        case "type":
            for itemType in ItemType.allCases {
                let keyName = itemType == .url ? "url" : itemType.rawValue
                let count = store.items.filter { $0.type == itemType }.count
                candidates.append(Candidate(
                    key: keyName,
                    display: keyName,
                    subtitle: itemType.tooltip,
                    icon: itemType.icon,
                    count: count
                ))
            }
            candidates.append(Candidate(key: "view", display: "view", subtitle: "Sidebar navigation views", icon: "sidebar.left", count: navigationViewsList.count))
            candidates.append(Candidate(key: "action", display: "action", subtitle: "Quick actions & commands", icon: "bolt.fill", count: quickActionsList.count))

        case "is":
            let seenIDs = store.seenItemIDs
            candidates = [
                Candidate(key: "recipe", display: "recipe", subtitle: "Items with recipe cards or #recipe", icon: "fork.knife", count: store.items.filter(\.isRecipe).count),
                Candidate(key: "unread", display: "unread", subtitle: "Unseen items", icon: "circle.fill", count: store.items.filter { !seenIDs.contains($0.id) }.count),
                Candidate(key: "starred", display: "starred", subtitle: "Starred items (#fav)", icon: "star.fill", count: store.items.filter { $0.tags?.contains(where: { $0.name.lowercased() == "fav" }) ?? false }.count),
                Candidate(key: "located", display: "located", subtitle: "Geotagged items with map coordinates", icon: "mappin.and.ellipse", count: store.items.filter { $0.location != nil }.count),
                Candidate(key: "annotated", display: "annotated", subtitle: "Items with notes", icon: "note.text", count: store.items.filter { !($0.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count),
                Candidate(key: "archived", display: "archived", subtitle: "Archived items", icon: "archivebox", count: 0)
            ]

        case "view":
            candidates = navigationViewsList.map { v in
                Candidate(key: v.title, display: v.title, subtitle: v.subtitle, icon: v.icon, count: 0)
            }

        case "action":
            candidates = quickActionsList.map { a in
                Candidate(key: a.title, display: a.title, subtitle: a.subtitle, icon: a.icon, count: 0)
            }

        default:
            suggestions = []
            suggestionIndex = -1
            return
        }

        let filtered = candidates
            .filter { c in
                partial.isEmpty || c.key.lowercased().contains(partial) || c.display.lowercased().contains(partial)
            }
            .sorted { a, b in
                if !partial.isEmpty {
                    let aPre = a.display.lowercased().hasPrefix(partial)
                    let bPre = b.display.lowercased().hasPrefix(partial)
                    if aPre != bPre { return aPre }
                }
                if a.count != b.count { return a.count > b.count }
                return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
            }
            .prefix(25)

        suggestions = filtered.map { c in
            let safeKey = (c.key.contains(" ") || c.key.contains(",")) ? "\"\(c.key)\"" : c.key
            return Suggestion(
                id: "val:\(tag):\(c.key.lowercased())",
                label: "\(tag):\(safeKey)",
                display: "\(tag):\(c.display)",
                subtitle: c.subtitle,
                icon: c.icon,
                count: c.count,
                command: nil
            )
        }
        suggestionIndex = suggestions.isEmpty ? -1 : 0
    }

    private func completeSuggestion(_ label: String) {
        let effectiveCursor = max(0, min(cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else { return }

        let trailingSpace = label.hasSuffix(":") ? "" : " "
        var newQuery = query
        newQuery.replaceSubrange(parsed.range, with: label + trailingSpace)

        lastSetQuery = newQuery
        query = newQuery

        let prefix = query[query.startIndex..<parsed.range.lowerBound]
        let newCursor = prefix.count + label.count + trailingSpace.count
        pendingCursor = newCursor
        cursorLocation = newCursor

        suggestions = []
        suggestionIndex = -1

        if label.hasSuffix(":") {
            let tag = canonicalTagName(String(label.dropLast()))
            populateTagValues(tag, partial: "")
        } else {
            debounceSearch(newQuery)
        }
    }

    private func iconForTag(_ label: String) -> String {
        let rawKey = label.split(separator: ":").first.map(String.init)?.lowercased() ?? label.lowercased()
        let key = canonicalTagName(rawKey)
        switch key {
        case "tag": return "tag"
        case "!tag": return "tag.slash"
        case "collection": return "folder"
        case "type": return "square.grid.2x2"
        case "is": return "sparkles"
        case "view": return "sidebar.left"
        case "action": return "bolt.fill"
        default: return "tag"
        }
    }

    // MARK: - Built-in Views & Quick Actions Catalog

    private struct ViewDescriptor {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let nav: NavigationItem
    }

    private var navigationViewsList: [ViewDescriptor] {
        var list: [ViewDescriptor] = [
            ViewDescriptor(id: "allItems", title: "All Items", subtitle: "Browse all stashed items", icon: "tray.full", nav: .allItems),
            ViewDescriptor(id: "inbox", title: "Inbox", subtitle: "Feed candidates, reading queue & resurfaced items", icon: "tray.and.arrow.down", nav: .inbox),
            ViewDescriptor(id: "starred", title: "Starred", subtitle: "Favorite items tagged #fav", icon: "star", nav: .starred),
            ViewDescriptor(id: "moments", title: "Moments", subtitle: "Photo & location clusters", icon: "photo.on.rectangle.angled", nav: .moments),
            ViewDescriptor(id: "tagGraph", title: "Tag Graph", subtitle: "Interactive tag co-occurrence graph", icon: "point.3.connected.trianglepath.dotted", nav: .tagGraph),
            ViewDescriptor(id: "rules", title: "Rules", subtitle: "Automated ingestion & tagging rules", icon: "slider.horizontal.3", nav: .rules),
            ViewDescriptor(id: "ruleActivity", title: "Rule Activity", subtitle: "Recent rule execution logs", icon: "list.bullet.clipboard", nav: .ruleActivity),
            ViewDescriptor(id: "dupes", title: "Duplicates", subtitle: "Find and merge duplicate items", icon: "rectangle.on.rectangle", nav: .dupes),
            ViewDescriptor(id: "check", title: "Health Check", subtitle: "Broken links, missing files & orphans", icon: "checkmark.shield", nav: .check),
            ViewDescriptor(id: "stats", title: "Statistics", subtitle: "Library size, item breakdown & growth", icon: "chart.bar", nav: .stats),
            ViewDescriptor(id: "archive", title: "Archive", subtitle: "Archived items", icon: "archivebox", nav: .archive)
        ]
        for col in store.collections {
            list.append(ViewDescriptor(
                id: "col-\(col.name)",
                title: col.name,
                subtitle: "Open Collection",
                icon: "folder",
                nav: .collection(col)
            ))
        }
        for saved in store.savedSearches {
            list.append(ViewDescriptor(
                id: "smart-\(saved.name)",
                title: saved.name,
                subtitle: "Smart Collection (\(saved.query))",
                icon: "sparkles",
                nav: .savedSearch(saved)
            ))
        }
        return list
    }

    private struct ActionDescriptor {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let perform: () -> Void
    }

    private var quickActionsList: [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "add-item",
                title: "Add Item…",
                subtitle: "Add a URL, file, or snippet to Stash (A)",
                icon: "plus.circle.fill",
                perform: { NotificationCenter.default.post(name: .stashOpenAddItem, object: nil) }
            ),
            ActionDescriptor(
                id: "fetch-url",
                title: "Fetch Files from URL…",
                subtitle: "Discover and import images, videos, or recipes from a web page (⇧⌘U)",
                icon: "link.badge.plus",
                perform: { NotificationCenter.default.post(name: .stashOpenFetchURL, object: nil) }
            ),
            ActionDescriptor(
                id: "new-collection",
                title: "New Collection…",
                subtitle: "Create a new static collection",
                icon: "folder.badge.plus",
                perform: { NotificationCenter.default.post(name: .stashOpenAddCollection, object: nil) }
            ),
            ActionDescriptor(
                id: "import-bookmarks",
                title: "Import Bookmarks…",
                subtitle: "Import browser bookmarks from Chrome or Firefox",
                icon: "book.circle",
                perform: { NotificationCenter.default.post(name: .stashOpenImportBookmarks, object: nil) }
            ),
            ActionDescriptor(
                id: "import-history",
                title: "Import Browser History…",
                subtitle: "Import browsing history entries",
                icon: "clock.arrow.circlepath",
                perform: { NotificationCenter.default.post(name: .stashOpenImportHistory, object: nil) }
            ),
            ActionDescriptor(
                id: "check",
                title: "Run Health Check",
                subtitle: "Verify blobs, broken URLs, and orphaned files (/check)",
                icon: "checkmark.shield",
                perform: { store.handleGlobalAction(.showCheck) }
            ),
            ActionDescriptor(
                id: "dupes",
                title: "Find Duplicate Items",
                subtitle: "Scan library for near-duplicate items (/dupes)",
                icon: "rectangle.on.rectangle",
                perform: { store.handleGlobalAction(.showDupes) }
            ),
            ActionDescriptor(
                id: "stats",
                title: "Show Library Statistics",
                subtitle: "View counts, storage usage, and tag distribution (/stats)",
                icon: "chart.bar",
                perform: { store.handleGlobalAction(.showStats) }
            ),
            ActionDescriptor(
                id: "backup",
                title: "Trigger Immediate Backup",
                subtitle: "Create a database backup snapshot (/backup)",
                icon: "externaldrive.badge.checkmark",
                perform: { store.handleGlobalAction(.backup) }
            ),
            ActionDescriptor(
                id: "reindex",
                title: "Rebuild Search Index",
                subtitle: "Reindex full-text search table (/reindex)",
                icon: "arrow.clockwise.circle",
                perform: { store.handleGlobalAction(.reindex) }
            ),
            ActionDescriptor(
                id: "data-dir",
                title: "Open Data Directory in Finder",
                subtitle: "Reveal ~/.stash in Finder (/data)",
                icon: "folder",
                perform: { store.handleGlobalAction(.openDataDir) }
            )
        ]
    }

    // MARK: - Search & Match Computation

    private enum SearchScope: Equatable {
        case all
        case itemType(ItemType)
        case view
        case action
    }

    private struct ParsedStashQuery {
        var scope: SearchScope
        var textQuery: String
        var tagTokens: [String]
        var excludeTagTokens: [String]
        var collectionToken: String?
        var isPredicates: [String]
        var archived: Bool
    }

    private func parseStashQuery(_ input: String) -> ParsedStashQuery {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if regexMode {
            return ParsedStashQuery(
                scope: .all,
                textQuery: trimmed,
                tagTokens: [],
                excludeTagTokens: [],
                collectionToken: nil,
                isPredicates: [],
                archived: false
            )
        }

        var scope: SearchScope = .all
        var tagTokens: [String] = []
        var excludeTagTokens: [String] = []
        var collectionToken: String? = nil
        var isPredicates: [String] = []
        var archived = false
        var freeWords: [String] = []

        for r in tokenRanges(in: trimmed) {
            let token = String(trimmed[r])
            if let colon = token.firstIndex(of: ":") {
                let rawKey = String(token[..<colon]).lowercased()
                let key = canonicalTagName(rawKey)
                var val = String(token[token.index(after: colon)...])
                if val.hasPrefix("\"") { val.removeFirst() }
                if val.hasSuffix("\"") { val.removeLast() }

                if globalStashFieldTags.contains(key) {
                    switch key {
                    case "tag":
                        if !val.isEmpty { tagTokens.append(val) }
                    case "!tag":
                        if !val.isEmpty { excludeTagTokens.append(val) }
                    case "collection":
                        if !val.isEmpty { collectionToken = val }
                    case "type":
                        let lowerVal = val.lowercased()
                        if lowerVal == "view" || lowerVal == "views" {
                            scope = .view
                        } else if lowerVal == "action" || lowerVal == "actions" {
                            scope = .action
                        } else if let resolved = StashStore.resolveItemType(from: lowerVal) {
                            scope = .itemType(resolved)
                        }
                    case "view":
                        scope = .view
                        if !val.isEmpty { freeWords.append(val) }
                    case "action":
                        scope = .action
                        if !val.isEmpty { freeWords.append(val) }
                    case "is":
                        let lowerVal = val.lowercased()
                        if lowerVal == "archived" {
                            archived = true
                        } else if lowerVal == "fav" || lowerVal == "starred" {
                            tagTokens.append("fav")
                        } else if !lowerVal.isEmpty {
                            isPredicates.append(lowerVal)
                        }
                    default:
                        break
                    }
                    continue
                }
            }
            freeWords.append(token)
        }

        return ParsedStashQuery(
            scope: scope,
            textQuery: freeWords.joined(separator: " ").trimmingCharacters(in: .whitespaces),
            tagTokens: tagTokens,
            excludeTagTokens: excludeTagTokens,
            collectionToken: collectionToken,
            isPredicates: isPredicates,
            archived: archived
        )
    }

    private func debounceSearch(_ currentQuery: String) {
        searchTask?.cancel()
        let trimmed = currentQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            regexError = nil
            searchError = nil
            rebuildMatches()
            return
        }

        let parsed = parseStashQuery(trimmed)
        if parsed.scope == .view || parsed.scope == .action {
            results = []
            regexError = nil
            searchError = nil
            rebuildMatches()
            return
        }

        let textQuery = parsed.textQuery
        let isSemantic = !regexMode && textQuery.hasPrefix("~")
        var finalQuery = isSemantic ? String(textQuery.dropFirst()).trimmingCharacters(in: .whitespaces) : textQuery

        if regexMode {
            if finalQuery.hasPrefix("/") && finalQuery.hasSuffix("/") && finalQuery.count >= 2 {
                finalQuery = String(finalQuery.dropFirst().dropLast())
            }
            let patternToValidate = finalQuery.hasPrefix("!") ? String(finalQuery.dropFirst()) : finalQuery
            if patternToValidate.isEmpty {
                results = []
                regexError = nil
                rebuildMatches()
                return
            }
            if (try? NSRegularExpression(pattern: patternToValidate)) == nil {
                regexError = "Invalid regex"
                results = []
                rebuildMatches()
                return
            }
            regexError = nil
        } else {
            regexError = nil
        }

        let itemTypeFilter: ItemType? = {
            if case .itemType(let t) = parsed.scope { return t }
            return nil
        }()
        let seenIDs = store.seenItemIDs

        // Rebuild view/action matches immediately while CLI search is in flight
        rebuildMatches()

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            do {
                let found: [StashItem]
                if regexMode {
                    found = try await StashCLI.shared.searchItems(
                        query: "",
                        limit: 50,
                        regex: finalQuery
                    )
                } else if finalQuery.isEmpty {
                    found = try await StashCLI.shared.listItems(
                        type: itemTypeFilter,
                        tags: parsed.tagTokens,
                        excludeTags: parsed.excludeTagTokens,
                        collection: parsed.collectionToken,
                        archived: parsed.archived,
                        limit: 40
                    )
                } else {
                    found = try await StashCLI.shared.searchItems(
                        query: finalQuery,
                        type: itemTypeFilter,
                        tags: parsed.tagTokens,
                        excludeTags: parsed.excludeTagTokens,
                        collection: parsed.collectionToken,
                        archived: parsed.archived,
                        limit: 40,
                        semantic: isSemantic
                    )
                }
                guard !Task.isCancelled else { return }
                let filtered = parsed.isPredicates.isEmpty
                    ? found
                    : found.filter { StashStore.matchesIsPredicates($0, predicates: parsed.isPredicates, seenIDs: seenIDs) }
                await MainActor.run {
                    results = filtered
                    searchError = nil
                    rebuildMatches()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchError = error.localizedDescription
                    results = []
                    rebuildMatches()
                }
            }
        }
    }

    private func rebuildMatches() {
        var built: [SearchResult] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            // 1. Saved Search History (Recent or Frequent based on browseMode)
            if browseMode == .frequent {
                for entry in history.prefix(8) {
                    built.append(makeHistoryResult(entry))
                }
            }

            // 2. Recent Items from navigationHistory (plus top recent items from store)
            var seenItemIDs = Set<String>()
            for snap in store.navigationHistory.reversed() {
                if let itemID = snap.selectedItemID,
                   !seenItemIDs.contains(itemID),
                   let item = store.items.first(where: { $0.id == itemID }) {
                    seenItemIDs.insert(itemID)
                    built.append(makeItemResult(item, badgeOverride: "Recent"))
                }
                if seenItemIDs.count >= 4 { break }
            }
            if seenItemIDs.count < 3 {
                for item in store.items.prefix(4) where !seenItemIDs.contains(item.id) {
                    seenItemIDs.insert(item.id)
                    built.append(makeItemResult(item, badgeOverride: "Recent"))
                    if seenItemIDs.count >= 4 { break }
                }
            }

            // 3. Recent Saved Searches (when browseMode == .recent)
            if browseMode == .recent {
                for entry in history.prefix(6) {
                    built.append(makeHistoryResult(entry))
                }
            }

            // 4. Quick Actions
            for act in quickActionsList.prefix(5) {
                built.append(SearchResult(
                    id: "action-\(act.id)",
                    title: act.title,
                    subtitle: act.subtitle,
                    typeBadge: "Action",
                    systemImage: act.icon,
                    payload: .action,
                    action: {
                        act.perform()
                        closePanel()
                    }
                ))
            }

            // 5. Filter Starters
            let starters: [(id: String, title: String, subtitle: String, icon: String, token: String)] = [
                ("starter-tag", "Filter by Tag", "Scope search by tag with tag:", "tag", "tag:"),
                ("starter-col", "Filter by Collection", "Scope search to a collection with collection:", "folder", "collection:"),
                ("starter-recipe", "Filter by Recipes", "Show stashed recipes with is:recipe", "fork.knife", "is:recipe "),
                ("starter-type", "Filter by Item Type", "Scope search by item type with type:", "square.grid.2x2", "type:")
            ]
            for s in starters {
                built.append(SearchResult(
                    id: s.id,
                    title: s.title,
                    subtitle: s.subtitle,
                    typeBadge: "Filter",
                    systemImage: s.icon,
                    payload: .filter(s.token),
                    action: {
                        cursorLocation = s.token.count
                        pendingCursor = s.token.count
                        query = s.token
                    }
                ))
            }

            matches = built
            activeIndex = built.isEmpty ? -1 : min(max(activeIndex, 0), built.count - 1)
            return
        }

        let parsed = parseStashQuery(trimmed)
        let lowerTerm = parsed.textQuery.lowercased()
        let hasItemOnlyFilters = !parsed.tagTokens.isEmpty || !parsed.excludeTagTokens.isEmpty || parsed.collectionToken != nil || !parsed.isPredicates.isEmpty || parsed.archived

        // Include matching Quick Actions when scope is .all or .action
        if !regexMode && !hasItemOnlyFilters && (parsed.scope == .all || parsed.scope == .action) {
            for act in quickActionsList {
                if parsed.scope == .action && lowerTerm.isEmpty {
                    built.append(SearchResult(
                        id: "action-\(act.id)",
                        title: act.title,
                        subtitle: act.subtitle,
                        typeBadge: "Action",
                        systemImage: act.icon,
                        payload: .action,
                        action: {
                            act.perform()
                            closePanel()
                        }
                    ))
                } else if !lowerTerm.isEmpty && (act.title.lowercased().contains(lowerTerm) || act.subtitle.lowercased().contains(lowerTerm)) {
                    built.append(SearchResult(
                        id: "action-\(act.id)",
                        title: act.title,
                        subtitle: act.subtitle,
                        typeBadge: "Action",
                        systemImage: act.icon,
                        payload: .action,
                        action: {
                            act.perform()
                            closePanel()
                        }
                    ))
                }
            }
        }

        // Include matching Navigation Views when scope is .all or .view
        if !regexMode && !hasItemOnlyFilters && (parsed.scope == .all || parsed.scope == .view) {
            for v in navigationViewsList {
                if parsed.scope == .view && lowerTerm.isEmpty {
                    built.append(SearchResult(
                        id: "view-\(v.id)",
                        title: v.title,
                        subtitle: v.subtitle,
                        typeBadge: "View",
                        systemImage: v.icon,
                        payload: .view(v.nav),
                        action: {
                            store.navigation = v.nav
                            closePanel()
                        }
                    ))
                } else if !lowerTerm.isEmpty && (v.title.lowercased().contains(lowerTerm) || v.subtitle.lowercased().contains(lowerTerm)) {
                    built.append(SearchResult(
                        id: "view-\(v.id)",
                        title: v.title,
                        subtitle: v.subtitle,
                        typeBadge: "View",
                        systemImage: v.icon,
                        payload: .view(v.nav),
                        action: {
                            store.navigation = v.nav
                            closePanel()
                        }
                    ))
                }
            }
        }

        // Stash Items from CLI search/list
        if parsed.scope != .view && parsed.scope != .action {
            for item in results {
                built.append(makeItemResult(item))
            }
        }

        matches = built
        activeIndex = built.isEmpty ? -1 : 0
    }

    private func makeItemResult(_ item: StashItem, badgeOverride: String? = nil) -> SearchResult {
        let tagLine = (item.tags ?? []).isEmpty
            ? nil
            : item.tags!.map { "#\($0.name)" }.joined(separator: " ")
        let sub = tagLine ?? item.url ?? item.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchResult(
            id: "\(badgeOverride ?? "item")-\(item.id)",
            title: item.title,
            subtitle: sub,
            typeBadge: badgeOverride ?? (item.isRecipe ? "Recipe" : item.type.label),
            systemImage: item.isRecipe ? "fork.knife" : item.iconName,
            payload: .item(item),
            action: {
                commitItemResult(item)
            }
        )
    }

    private func makeHistoryResult(_ entry: SearchHistoryEntry) -> SearchResult {
        let sub = browseMode == .recent
            ? "Saved search • \(entry.lastUsedAt.formatted(.relative(presentation: .numeric)))"
            : "Saved search • Used \(entry.count)×"
        return SearchResult(
            id: "history-\(entry.query)",
            title: entry.query,
            subtitle: sub,
            typeBadge: "History",
            systemImage: browseMode == .recent ? "clock" : "chart.bar",
            payload: .history(entry),
            action: {
                cursorLocation = entry.query.count
                pendingCursor = entry.query.count
                query = entry.query
            }
        )
    }

    private func commitSelectedMatch() {
        guard activeIndex >= 0 && activeIndex < matches.count else { return }
        let selected = matches[activeIndex]
        selected.action()
    }

    private func commitItemResult(_ item: StashItem) {
        let committed = query.trimmingCharacters(in: .whitespaces)
        if !committed.isEmpty {
            Task {
                try? await StashCLI.shared.recordSearchClick(query: committed, itemID: item.id)
            }
        }
        store.selectItemByID(item.id, revealInList: true)
        closePanel()
    }

    private func reloadHistory() async {
        do {
            history = try await StashCLI.shared.listSearchHistory(
                sort: browseMode.rawValue,
                limit: 25
            )
        } catch {
            history = []
        }
    }

    // MARK: - Result Row & Context Menu

    @ViewBuilder
    private func resultRow(idx: Int, match: SearchResult) -> some View {
        let active = idx == activeIndex
        Button {
            activeIndex = idx
            match.action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: match.systemImage)
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(match.title)
                        .font(.body.weight(active ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let sub = match.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(match.typeBadge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? Color.accentColor.opacity(isResultsFocused ? 0.3 : 0.2) : Color.clear)
            .overlay(alignment: .leading) {
                if isResultsFocused && active {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointingHandCursor()
        .contextMenu {
            resultContextMenu(for: match)
        }
    }

    @ViewBuilder
    private func resultContextMenu(for match: SearchResult) -> some View {
        switch match.payload {
        case .item(let item):
            Button("Open") {
                store.openItem(id: item.id)
                closePanel()
            }
            Button("Reveal in List") {
                commitItemResult(item)
            }
            Button("Send to Phone (⌘⇧O)") {
                if let idx = matches.firstIndex(where: { $0.id == match.id }) {
                    activeIndex = idx
                }
                phoneHandoffShown = true
            }
            if let url = item.url, !url.isEmpty {
                Button("Copy URL") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(url, forType: .string)
                }
            }
            Button("Edit…") {
                store.selectItemByID(item.id, revealInList: true)
                NotificationCenter.default.post(name: .stashOpenEditItem, object: nil)
                closePanel()
            }
            Divider()
            Button("Archive") {
                store.archiveItems(ids: [item.id])
            }
            Button("Delete", role: .destructive) {
                store.deleteItem(id: item.id)
            }
        case .history(let entry):
            Button("Run Search") {
                match.action()
            }
            Divider()
            Button("Delete from History", role: .destructive) {
                Task {
                    try? await StashCLI.shared.deleteSearchHistoryEntry(query: entry.query)
                    await reloadHistory()
                    rebuildMatches()
                }
            }
        default:
            Button("Select") {
                match.action()
            }
        }
    }

    // MARK: - Right-Hand Live Preview Pane

    @ViewBuilder
    private func previewPane(for match: SearchResult) -> some View {
        switch match.payload {
        case .item(let item):
            itemPreview(for: item)
        case .history(let entry):
            historyPreview(for: entry)
        case .view:
            genericPreview(for: match, hint: "Press Enter or Return to navigate to view")
        case .action:
            genericPreview(for: match, hint: "Press Enter or Return to run action")
        case .filter:
            genericPreview(for: match, hint: "Press Enter or Return to insert filter chip")
        }
    }

    @ViewBuilder
    private func itemPreview(for item: StashItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Thumbnail / Image preview banner
                if let thumbRel = item.thumbnailPath {
                    AsyncThumbnailImage(relativePath: thumbRel) {
                        EmptyView()
                    } configure: { img in
                        AnyView(
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 150)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        )
                    }
                }

                // Title & badges
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Label(item.type.label, systemImage: item.iconName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)

                        if item.isRecipe {
                            Label("Recipe", systemImage: "fork.knife")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }

                        if !store.seenItemIDs.contains(item.id) {
                            Text("Unread")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                }

                // Metadata rows
                VStack(alignment: .leading, spacing: 6) {
                    if let url = item.url, !url.isEmpty {
                        Label(url, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if let from = item.fromName {
                        Label(from, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let size = item.humanFileSize {
                        Label("\(size)\(item.mimeType.map { " • \($0)" } ?? "")", systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Label("Added \(item.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let loc = item.location {
                        Label(String(format: "%.4f, %.4f", loc.lat, loc.lon), systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Tags & Collections
                if let tags = item.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tags) { tag in
                                Button {
                                    toggleChipToken("tag:\(tag.name)")
                                } label: {
                                    Text("#\(tag.name)")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.14), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .pointingHandCursor()
                                .help("Click to filter by tag:\(tag.name)")
                            }
                        }
                    }
                }

                if let cols = item.collections, !cols.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(cols) { col in
                                Button {
                                    let safe = col.name.contains(" ") ? "\"\(col.name)\"" : col.name
                                    toggleChipToken("collection:\(safe)")
                                } label: {
                                    Label(col.name, systemImage: "folder")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .pointingHandCursor()
                                .help("Click to filter by collection:\(col.name)")
                            }
                        }
                    }
                }

                // Recipe card preview
                if let recipe = item.recipe {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            if let yld = recipe.yield, !yld.isEmpty {
                                Label(yld, systemImage: "person.2")
                            }
                            if let total = recipe.totalTime, !total.isEmpty {
                                Label(total, systemImage: "clock")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        if !recipe.ingredients.isEmpty {
                            Text("\(recipe.ingredients.count) ingredients • \(recipe.instructions.count) steps")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }
                }

                // Notes / Extracted text snippet
                let bodyText = (item.notes?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (item.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                if let bodyText {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.notes?.isEmpty == false ? "Notes" : "Content Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(bodyText)
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(6)
                    }
                }

                Divider()

                // Quick action buttons
                HStack(spacing: 8) {
                    Button {
                        store.openItem(id: item.id)
                        closePanel()
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .focusable(false)
                    .pointingHandCursor()

                    Button {
                        commitItemResult(item)
                    } label: {
                        Label("Reveal", systemImage: "sidebar.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                    .pointingHandCursor()

                    PhoneHandoffButton(
                        payload: .from(item: item),
                        controlSize: .small,
                        externalIsPresented: $phoneHandoffShown
                    )

                    if let url = item.url, !url.isEmpty {
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(url, forType: .string)
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                        .pointingHandCursor()
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func historyPreview(for entry: SearchHistoryEntry) -> some View {
        VStack(spacing: 12) {
            Image(systemName: browseMode == .recent ? "clock.arrow.circlepath" : "chart.bar.xaxis")
                .font(.system(size: 38))
                .foregroundStyle(Color.accentColor)
            Text(entry.query)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("Used \(entry.count) time\(entry.count == 1 ? "" : "s") • Last used \(entry.lastUsedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    cursorLocation = entry.query.count
                    pendingCursor = entry.query.count
                    query = entry.query
                } label: {
                    Label("Run Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .focusable(false)
                .pointingHandCursor()

                Button(role: .destructive) {
                    Task {
                        try? await StashCLI.shared.deleteSearchHistoryEntry(query: entry.query)
                        await reloadHistory()
                        rebuildMatches()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
                .pointingHandCursor()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func genericPreview(for match: SearchResult, hint: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: match.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text(match.title)
                .font(.headline)
            if let sub = match.subtitle {
                Text(sub)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
