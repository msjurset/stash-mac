import SwiftUI

/// Shared mutable state that the event monitor reads directly — no SwiftUI
/// render cycle needed, so it's always current when a key event arrives.
@Observable
@MainActor
final class TagSuggestionState {
    var matches: [StashTag] = []
    var activeIndex = -1
    var justAccepted = false
    var isNavigating = false
    var onNavigate: ((QuickSearchView.Direction) -> Void)?
    var onAccept: (() -> Void)?
}

struct ItemListView: View {
    @Environment(StashStore.self) private var store
    @Binding var showEditSheet: Bool

    @State private var state = TagSuggestionState()
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search items... (tag: to filter)", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { store.refresh() }
                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                        state.matches = []
                        store.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)

            Divider()

            // Tag suggestions
            if !state.matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.matches.enumerated()), id: \.element.id) { idx, tag in
                        Button {
                            completeTag(tag.name)
                        } label: {
                            HStack {
                                Image(systemName: "tag")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text("tag:\(tag.name)")
                                Spacer()
                                if let count = tag.count {
                                    Text("\(count)")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(idx == state.activeIndex ? Color.accentColor.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .background(.bar)
                Divider()
            }

            // Item list
            List(selection: $store.selectedItemID) {
                HStack {
                    Text("\(store.items.count) \(store.items.count == 1 ? "item" : "items")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.cycleSortMode()
                    } label: {
                        HStack(spacing: 2) {
                            Text(store.sortMode.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Image(systemName: store.sortMode.icon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sort: \(store.sortMode.rawValue)")
                }
                .listRowSeparator(.hidden)
                ForEach(store.items) { item in
                    ItemRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Open") { store.openItem(id: item.id) }
                            Button("Edit...") {
                                store.selectedItemID = item.id
                                showEditSheet = true
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.deleteItem(id: item.id)
                            }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.searchQuery) { _, _ in
            if state.isNavigating {
                state.isNavigating = false
                return
            }
            state.justAccepted = false
            updateTagSuggestions()
            if state.matches.isEmpty {
                store.debouncedRefresh()
            }
        }
        .background(SearchFieldKeyMonitor(state: state))
        .onAppear {
            state.onNavigate = { navigate($0) }
            state.onAccept = { handleEnter() }
        }
        .overlay {
            if store.items.isEmpty && !store.isLoading && state.matches.isEmpty {
                ContentUnavailableView("No Items", systemImage: "tray", description: Text("Add items with the + button or drag files here."))
            }
        }
        .overlay {
            if store.isLoading && store.items.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem {
                ContextualHelpButton(topic: .searching)
            }
        }
    }

    // MARK: - Tag Suggestion Logic

    private func updateTagSuggestions() {
        state.activeIndex = -1
        let query = store.searchQuery
        guard let match = query.range(of: #"(?:^|\s)tag:(\S*)$"#, options: .regularExpression) else {
            state.matches = []
            return
        }
        let token = query[match]
        guard let colonIdx = token.firstIndex(of: ":") else {
            state.matches = []
            return
        }
        let partial = String(token[token.index(after: colonIdx)...]).lowercased()

        let existing = Set(
            query.matches(of: /tag:(\S+)/).map { String($0.output.1).lowercased() }
        )

        state.matches = store.tags
            .filter { tag in
                let lower = tag.name.lowercased()
                return (partial.isEmpty || lower.contains(partial)) && !existing.contains(lower)
            }
            .prefix(8)
            .map { $0 }
    }

    private func navigate(_ direction: QuickSearchView.Direction) {
        guard !state.matches.isEmpty else { return }
        switch direction {
        case .down:
            state.activeIndex = state.activeIndex < 0 ? 0 : min(state.activeIndex + 1, state.matches.count - 1)
        case .up:
            state.activeIndex = max(state.activeIndex - 1, 0)
        }
        previewTag(state.matches[state.activeIndex].name)
    }

    private func handleEnter() {
        if !state.matches.isEmpty {
            let idx = state.activeIndex >= 0 ? state.activeIndex : 0
            if idx < state.matches.count {
                completeTag(state.matches[idx].name)
            }
            state.justAccepted = true
            return
        }
        if state.justAccepted {
            state.justAccepted = false
            store.refresh()
        }
    }

    private func previewTag(_ tagName: String) {
        guard let range = store.searchQuery.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) else { return }
        let query = store.searchQuery
        let before = query[query.startIndex..<range.lowerBound]
        let prefix = query[range].hasPrefix(" ") ? " " : ""
        state.isNavigating = true
        store.searchQuery = "\(before)\(prefix)tag:\(tagName)"
    }

    private func completeTag(_ tagName: String) {
        guard let range = store.searchQuery.range(of: #"(?:^|\s)tag:\S*$"#, options: .regularExpression) else { return }
        let query = store.searchQuery
        let before = query[query.startIndex..<range.lowerBound]
        let prefix = query[range].hasPrefix(" ") ? " " : ""
        store.searchQuery = "\(before)\(prefix)tag:\(tagName) "
        state.matches = []
        store.debouncedRefresh()
    }
}

/// Intercepts Tab, Ctrl-J/K, arrows, and Enter in the search field.
/// Reads from the shared TagSuggestionState reference (always current).
struct SearchFieldKeyMonitor: NSViewRepresentable {
    let state: TagSuggestionState

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class MonitorView: NSView {
        var state: TagSuggestionState?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let state = self.state else { return event }

                guard self.window?.firstResponder is NSTextView else { return event }

                let ctrl = event.modifierFlags.contains(.control)
                let char = event.charactersIgnoringModifiers
                let keyCode = event.keyCode

                let hasSuggestions = MainActor.assumeIsolated { !state.matches.isEmpty }
                let justAccepted = MainActor.assumeIsolated { state.justAccepted }

                if hasSuggestions {
                    if keyCode == 48 && !ctrl {
                        MainActor.assumeIsolated { state.onNavigate?(.down) }
                        return nil
                    }
                    if (ctrl && char == "j") || keyCode == 125 {
                        MainActor.assumeIsolated { state.onNavigate?(.down) }
                        return nil
                    }
                    if (ctrl && char == "k") || keyCode == 126 {
                        MainActor.assumeIsolated { state.onNavigate?(.up) }
                        return nil
                    }
                    if keyCode == 36 {
                        MainActor.assumeIsolated { state.onAccept?() }
                        return nil
                    }
                }

                if keyCode == 36 && justAccepted {
                    MainActor.assumeIsolated { state.onAccept?() }
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
