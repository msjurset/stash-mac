import SwiftUI
import AppKit

/// Shared mutable state that the event monitor reads directly — no SwiftUI
/// render cycle needed, so it's always current when a key event arrives.
@Observable
@MainActor
final class TagSuggestionState {
    struct Suggestion: Identifiable, Equatable {
        let id: String
        let label: String
        let display: String
        let subtitle: String?
        let icon: String
        let count: Int
    }

    var matches: [Suggestion] = []
    var activeIndex = 0
    var cursorLocation = 0
    var lastSetQuery: String? = nil
    var suggestionTask: Task<Void, Never>?
    /// Returns `true` if the event was consumed.
    var onKey: ((SuggestKey) -> Bool)?
    /// True while the items-list search FilterField is the first
    /// responder. The window-wide keyDown monitor checks this
    /// before forwarding Tab/Arrow/Enter — without it, focus in
    /// ANY NSTextView (e.g. the detail-pane tag input) would
    /// route those keys into the items-list search's tag-cycler.
    var isSearchFocused: Bool = false
}

private let listSearchFieldTags = ["tag", "!tag", "collection", "type", "is"]

struct ItemListView: View {
    @Environment(StashStore.self) private var store
    @Environment(AIPrefsStore.self) private var aiPrefs
    @Binding var showEditSheet: Bool

    @State private var state = TagSuggestionState()
    @State private var regexGuideShown = false
    @State private var pendingCursor: Int? = nil
    @State private var searchFocusTrigger: Int = 0

    /// Drives the per-row Tags popover. When non-nil, the popover
    /// is presented anchored to the row whose id matches `id`. The
    /// payload (`itemIDs`, `initialTags`) is captured at right-click
    /// time so the picker stays stable even if the underlying list
    /// reloads while the popover is open.
    @State private var tagPickerTarget: TagPickerTarget?

    /// Row whose thumbnail popover is currently showing, or nil for
    /// none. Triggered by clicking the leading icon — single-id
    /// state so clicking icon B atomically dismisses A's popover
    /// and opens B's. Re-clicking the same icon toggles closed.
    /// Clicks elsewhere dismiss via the OS popover default + an
    /// inside-popover tap gesture.
    @State private var shownThumbnailID: String?

    /// Merge-items picker state. Single Identifiable optional so
    /// the `.sheet(item:)` content closure gets the IDs directly
    /// instead of relying on two separate @State updates landing in
    /// the right order — the previous showBool+idsArray version
    /// silently presented with 0 items because the array update
    /// hadn't propagated before the sheet body ran.
    @State private var mergeRequest: MergeRequest?
    @State private var linkRequest: LinkRequest?

    struct MergeRequest: Identifiable {
        let id = UUID()
        let itemIDs: [String]
    }

    struct LinkRequest: Identifiable {
        let id = UUID()
        let sourceID: String
        let targetID: String?
    }

    struct TagPickerTarget: Equatable {
        let id: String                 // the right-clicked row id (anchor)
        let itemIDs: [String]          // items the picker applies to
        let initialTags: Set<String>   // common tags across `itemIDs`
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                FilterField(
                    placeholder: store.regexMode ? "Regex search... /pattern/ (! to negate)" : "Search items... (Tab/Enter for tag: collection: type: is:)",
                    text: $store.searchQuery,
                    focusTrigger: searchFocusTrigger,
                    pendingCursor: $pendingCursor,
                    onSelectionChanged: { loc in
                        state.cursorLocation = loc
                        recomputeSuggestions()
                    },
                    onSubmit: { store.refresh() },
                    onBeginEditing: {
                        state.isSearchFocused = true
                        recomputeSuggestions()
                    },
                    onEndEditing:   { state.isSearchFocused = false }
                )
                // Regex toggle (*) inside the search bar area
                Button {
                    store.regexMode.toggle()
                    if store.regexMode {
                        state.matches = []
                        regexGuideShown = true
                    } else {
                        regexGuideShown = false
                        recomputeSuggestions()
                    }
                    store.refresh()
                } label: {
                    Image(systemName: "asterisk")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(store.regexMode ? Color.white : Color.secondary)
                        .frame(width: 20, height: 20)
                        .background(store.regexMode ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(store.regexMode ? "Regex search active — click to disable" : "Search by regex — click to enable")
                .background(
                    PersistentPopoverHost(
                        isPresented: $regexGuideShown,
                        preferredEdge: .minY
                    ) {
                        RegexGuideView(context: .searchPanel)
                    }
                )

                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                        state.matches = []
                        state.cursorLocation = 0
                        store.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
            .helpAnchor(.searchBar)
            .onChange(of: store.searchQuery) { _, newQuery in
                // "//" auto-detection for regex mode
                if newQuery == "//" && !store.regexMode {
                    store.regexMode = true
                    regexGuideShown = true
                    state.matches = []
                    pendingCursor = 1
                    state.cursorLocation = 1
                    store.debouncedRefresh()
                    return
                }
                if let last = state.lastSetQuery, last == newQuery {
                    state.lastSetQuery = nil
                    store.debouncedRefresh()
                    return
                }
                state.lastSetQuery = nil
                recomputeSuggestions()
                store.debouncedRefresh()
            }

            // Type filter chips. Replaces the per-type sidebar entries
            // we had before — discoverable in the items pane itself.
            // Fires `selectFilterType` so it composes correctly with
            // sidebar tag/collection filters and the search query.
            typeFilterBar
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
                .helpAnchor(.filterBar)

            Divider()

            // Chip suggestions
            if state.isSearchFocused && !state.matches.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(state.matches.enumerated()), id: \.element.id) { idx, suggestion in
                                Button {
                                    completeSuggestion(suggestion.label)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: suggestion.icon)
                                            .foregroundStyle(idx == state.activeIndex ? Color.accentColor : .secondary)
                                            .frame(width: 16)
                                        Text(suggestion.display)
                                            .font(.callout.weight(idx == state.activeIndex ? .semibold : .regular))
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
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(idx == state.activeIndex ? Color.accentColor.opacity(0.2) : .clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .pointingHandCursor()
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: min(CGFloat(state.matches.count) * 26 + 8, 240))
                    .background(.bar)
                    .onChange(of: state.activeIndex) { _, newIdx in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
                Divider()
            }

            // Header bar — count, sort cycle, list/grid toggle. Lives
            // above both the list and the grid renderings so it stays
            // visible regardless of view mode.
            paneHeader

            // Item list, grid, or masonry. Selection is a Set so
            // Cmd-click / Shift-click multi-select. The detail pane
            // pivots off `store.selectedItemID`, which is kept in
            // sync below.
            //
            // Collection navigation (sidebar Collections section)
            // hard-switches to masonry — the visual emphasis matches
            // the curated, often photo-heavy nature of collections.
            // The list/grid toggle still works as an escape hatch.
            if isCollectionNavigation && store.viewMode == .grid {
                masonryView
                    .helpAnchor(.navigationList)
            } else if store.viewMode == .grid {
                gridView
                    .helpAnchor(.navigationList)
            } else {
                listView
                    .helpAnchor(.navigationList)
            }
        }
        .onKeyPress(.space) {
            // Ignore spacebar for QuickLook if a modal sheet (such as CookingWizardView or FetchURLSheet)
            // is active or if a text field is focused (typing).
            if let keyWin = NSApp.keyWindow,
               (keyWin.isSheet || keyWin.attachedSheet != nil) {
                return .ignored
            }
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               (firstResponder is NSTextView || firstResponder is NSTextField) {
                return .ignored
            }
            let targets = quickLookTargets()
            if targets.isEmpty { return .ignored }
            QuickLookPreviewer.shared.show(items: targets)
            return .handled
        }
        // ⌘-Return on the items list opens the current selection — same
        // behavior as double-click and the context menu "Open" action.
        // Plain Return is intentionally left alone since inline-rename
        // and detail-pane field handlers may want it. Multi-select opens
        // each in turn.
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let ids = Array(store.selectedItems)
            if ids.isEmpty { return .ignored }
            for id in ids { store.openItem(id: id) }
            return .handled
        }
        .onChange(of: store.navigation) { _, new in
            // Hard-switch to grid (= masonry, since `gridView` reads
            // `isCollectionNavigation`) when the user clicks a sidebar
            // Collection. The toggle is still available so they can
            // flip back to list within a collection. Also default
            // sortMode to .curated so the CLI's drag-and-drop order
            // surfaces in the UI.
            if case .collection = new {
                if store.viewMode != .grid {
                    store.viewMode = .grid
                }
                if store.sortMode != .curated {
                    store.sortMode = .curated
                }
            } else if store.sortMode == .curated {
                // Leaving a collection: .curated is redundant with
                // newest-first elsewhere, so revert.
                store.sortMode = .newestFirst
            }
        }
        .onChange(of: store.selectedItems) { _, newSelection in
            // Detail pane shows the focused row, which we define as
            // "the only selected row." Multi-select hides the detail
            // (caller can navigate or shrink the selection back to 1).
            if newSelection.count == 1 {
                store.selectedItemID = newSelection.first
            } else if newSelection.isEmpty {
                store.selectedItemID = nil
            } else {
                if let current = store.selectedItemID,
                   !newSelection.contains(current) {
                    store.selectedItemID = nil
                }
            }
        }
        .background(SearchFieldKeyMonitor(state: state))
        .onAppear {
            state.onKey = { handleKey($0) }
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
        .onAppear { store.installItemDragMonitor() }
        .onDisappear { store.removeItemDragMonitor() }
        // Merge picker sheet — attached at body level (not on a
        // specific view-mode branch) so it presents from list,
        // grid, and masonry views the same way. Uses .sheet(item:)
        // so the IDs are passed in alongside the present-true
        // signal in one state mutation — avoids the empty-payload
        // race the two-@State version had.
        .sheet(item: $mergeRequest) { req in
            MergeItemsSheet(
                items: req.itemIDs.compactMap { id in
                    store.items.first(where: { $0.id == id })
                },
                onMerge: { targetID, sourceIDs in
                    store.mergeItems(targetID: targetID, sourceIDs: sourceIDs)
                    store.selectedItems = [targetID]
                    mergeRequest = nil
                },
                onCancel: { mergeRequest = nil }
            )
        }
        .sheet(item: $linkRequest) { req in
            LinkItemSheet(sourceItemID: req.sourceID, targetItemID: req.targetID)
        }
    }

    /// True when the current navigation is a sidebar Collection.
    /// Drives the masonry-vs-uniform-grid choice when the user has
    /// toggled grid mode.
    private var isCollectionNavigation: Bool {
        if case .collection = store.navigation { return true }
        return false
    }

    private var masonryView: some View {
        MasonryGrid(
            items: store.items,
            onTap: { item in handleTileClick(item: item) },
            onOpen: { item in store.openItem(id: item.id) },
            contextMenuBuilder: { id in
                AnyView(itemContextMenu(rightClickedID: id, inGridView: true))
            },
            dragString: { id in dragString(for: id) },
            onReorderBefore: { droppedIDs, targetID in
                store.reorderCollectionInsertBefore(
                    droppedIDs: droppedIDs,
                    targetID: targetID
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paneHeader: some View {
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
            .focusable(false)
            .help("Sort: \(store.sortMode.rawValue)")

            Button {
                store.toggleViewMode()
            } label: {
                Image(systemName: store.viewMode == .grid
                    ? "list.bullet"
                    : "square.grid.2x2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(store.viewMode == .grid ? "Switch to list" : "Switch to grid")
            
            ContextualHelpButton(topic: .searching)
                .font(.caption2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var listView: some View {
        @Bindable var store = store
        return ScrollViewReader { proxy in
            List(selection: $store.selectedItems) {
            ForEach(store.items) { item in
                let idx = store.indexOfItem(id: item.id) ?? 0
                ItemRow(item: item, shownThumbnailID: $shownThumbnailID)
                    .listRowBackground(idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                    .tag(item.id)
                    .id(item.id)
                    // No row-level tap gesture: SwiftUI's tap detection
                    // either misses non-hittable areas (icon-only with
                    // text behind `.allowsHitTesting(false)`) or
                    // captures single clicks during its tap-count window
                    // (breaking row selection + drag). Double-click is
                    // handled at the AppKit level by
                    // `installItemDragMonitor`'s clickCount detection,
                    // which works across the entire row regardless of
                    // child hit-test settings.
                    .draggable(dragString(for: item.id))
                    // Drop on a list row in a collection nav reorders
                    // the curated order. No-op outside collection nav
                    // (no place to persist a custom order).
                    .modifier(CollectionRowReorderModifier(
                        enabled: isCollectionNavigation,
                        targetID: item.id
                    ))
                    .contextMenu { itemContextMenu(rightClickedID: item.id) }
                    .popover(
                        isPresented: Binding(
                            get: { tagPickerTarget?.id == item.id },
                            set: { newValue in
                                if !newValue && tagPickerTarget?.id == item.id {
                                    tagPickerTarget = nil
                                }
                            }
                        ),
                        arrowEdge: .leading
                    ) {
                        if let target = tagPickerTarget,
                           target.id == item.id {
                            TagPickerPopover(
                                itemIDs: target.itemIDs,
                                initialTags: target.initialTags
                            )
                        }
                    }
            }
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // QuickSearch / Health Check / other "reveal" callers set
            // store.pendingRevealID. Scroll to it once the items have
            // populated, then clear the signal so the same id can be
            // re-requested later.
            .onChange(of: store.pendingRevealID) { _, id in
                guard let id else { return }
                scrollToPending(id, proxy: proxy)
            }
            .onChange(of: store.items) { _, _ in
                if let id = store.pendingRevealID {
                    scrollToPending(id, proxy: proxy)
                }
            }
        }
    }

    private func scrollToPending(_ id: String, proxy: ScrollViewProxy) {
        guard store.items.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
            store.pendingRevealID = nil
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                // alignment: .top so tiles with single-line vs
                // two-line captions in the same row anchor their
                // images at the same Y. Default .center pushed
                // short-caption images downward to match the taller
                // cell, giving the grid a visibly mis-aligned look.
                columns: [GridItem(.adaptive(minimum: 140, maximum: 200),
                                   spacing: 14,
                                   alignment: .top)],
                spacing: 14
            ) {
                ForEach(store.items) { item in
                    ItemTile(item: item)
                        .onTapGesture(count: 2) {
                            store.openItem(id: item.id)
                        }
                        .onTapGesture {
                            handleTileClick(item: item)
                        }
                        .draggable(dragString(for: item.id))
                        .contextMenu { itemContextMenu(rightClickedID: item.id, inGridView: true) }
                        .popover(
                            isPresented: Binding(
                                get: { tagPickerTarget?.id == item.id },
                                set: { newValue in
                                    if !newValue && tagPickerTarget?.id == item.id {
                                        tagPickerTarget = nil
                                    }
                                }
                            ),
                            arrowEdge: .leading
                        ) {
                            if let target = tagPickerTarget,
                               target.id == item.id {
                                TagPickerPopover(
                                    itemIDs: target.itemIDs,
                                    initialTags: target.initialTags
                                )
                            }
                        }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tile click handling — modifier-aware multi-select that
    /// mirrors the List's native Cmd-click toggle behavior. SwiftUI
    /// LazyVGrid doesn't have a `selection:` binding so we drive
    /// `store.selectedItems` manually.
    private func handleTileClick(item: StashItem) {
        let cmd = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if cmd {
            if store.selectedItems.contains(item.id) {
                store.selectedItems.remove(item.id)
            } else {
                store.selectedItems.insert(item.id)
            }
        } else if shift, let anchor = store.selectedItemID,
                  let lo = store.items.firstIndex(where: { $0.id == anchor }),
                  let hi = store.items.firstIndex(where: { $0.id == item.id }) {
            let range = lo <= hi ? lo...hi : hi...lo
            store.selectedItems = Set(store.items[range].map(\.id))
        } else {
            store.selectedItems = [item.id]
        }
    }

    // MARK: - Type filter bar

    /// Pill / segmented filter row that lets the user narrow the items
    /// list to a single type. Replaces the per-type sidebar entries.
    /// "All" clears `filterType` and shows everything; the others set
    /// `filterType` to the corresponding `ItemType`. Selection highlight
    /// is keyed off `store.filterType`, not navigation, so it stays
    /// correct across sidebar tag / collection picks.
    ///
    /// Wrapped in a horizontal `ScrollView` so labels never break onto
    /// two lines when the pane is narrow — pills stay full-width and
    /// scroll instead.
    private var typeFilterBar: some View {
        let knownSet = Set(["tag", "t", "collection", "col", "c", "type", "is"])
        let activeTokens = store.regexMode
            ? []
            : SearchTokenHelper.extractStructuredTokens(from: store.searchQuery, knownKeys: knownSet)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(activeTokens, id: \.self) { tok in
                    let keyPart = tok.split(separator: ":").first.map(String.init) ?? tok
                    let displayLabel = tok.replacingOccurrences(of: "\"", with: "")
                    Button {
                        let updated = SearchTokenHelper.removeChip(tok, from: store.searchQuery)
                        let finalQuery = updated.isEmpty ? "" : (updated.hasSuffix(" ") ? updated : updated + " ")
                        state.lastSetQuery = finalQuery
                        store.searchQuery = finalQuery
                        state.matches = []
                        pendingCursor = finalQuery.count
                        state.cursorLocation = finalQuery.count
                        store.debouncedRefresh()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconForListTag("\(keyPart):"))
                                .font(.system(size: 10, weight: .semibold))
                            Text(displayLabel)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.leading, 1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .pointingHandCursor()
                    .help("Click to remove filter \(displayLabel)")
                }

                TypeChipView(
                    label: "All",
                    icon: "tray.full",
                    tooltip: "Show all item types",
                    value: nil,
                    selectedValue: store.filterType,
                    onSelect: {
                        store.filterType = nil
                        store.debouncedRefresh()
                    }
                )
                ForEach(ItemType.allCases) { t in
                    TypeChipView(
                        label: t.label,
                        icon: t.icon,
                        tooltip: t.tooltip,
                        value: t,
                        selectedValue: store.filterType,
                        onSelect: {
                            store.filterType = t
                            store.debouncedRefresh()
                        }
                    )
                }
            }
        }
    }


    // MARK: - Suggestion logic

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

    private func canonicalListTagName(_ raw: String) -> String {
        switch raw {
        case "t", "tags": return "tag"
        case "-tag", "^tag", "!t": return "!tag"
        case "col", "c", "collections", "folder": return "collection"
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
            let canonicalTag = canonicalListTagName(rawTag)
            var partial = String(token[token.index(after: colonIdx)...]).lowercased()
            if partial.hasPrefix("\"") { partial.removeFirst() }
            if partial.hasSuffix("\"") { partial.removeLast() }
            if listSearchFieldTags.contains(canonicalTag) {
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
                let key = canonicalListTagName(rawKey)
                if listSearchFieldTags.contains(key) && !multiAllowed.contains(key) {
                    used.insert(key)
                }
            }
        }
        return used
    }

    private func showAllUnusedKeys(in text: String, partial: String = "") {
        let used = usedSingleValueKeys(in: text)
        let matchingKeys = listSearchFieldTags.filter {
            !used.contains($0) && (partial.isEmpty || ($0.hasPrefix(partial) && $0 != partial))
        }
        state.matches = matchingKeys.map { key in
            TagSuggestionState.Suggestion(
                id: "key:\(key)",
                label: "\(key):",
                display: "\(key):",
                subtitle: listTagDescription(key),
                icon: iconForListTag("\(key):"),
                count: 0
            )
        }
        state.activeIndex = 0
    }

    private func listTagDescription(_ key: String) -> String {
        switch key {
        case "tag": return "Filter items by tag"
        case "!tag": return "Exclude items with tag"
        case "collection": return "Filter items by collection"
        case "type": return "Filter by item type (url, snippet, image, file, audio, email)"
        case "is": return "Filter by status (recipe, unread, starred, located, annotated, archived)"
        default: return ""
        }
    }

    private func iconForListTag(_ label: String) -> String {
        let rawKey = label.split(separator: ":").first.map(String.init)?.lowercased() ?? label.lowercased()
        let key = canonicalListTagName(rawKey)
        switch key {
        case "tag": return "tag"
        case "!tag": return "tag.slash"
        case "collection": return "folder"
        case "type": return "square.grid.2x2"
        case "is": return "sparkles"
        default: return "tag"
        }
    }

    private func recomputeSuggestions() {
        state.suggestionTask?.cancel()
        if store.regexMode {
            state.matches = []
            state.activeIndex = 0
            return
        }

        let query = store.searchQuery
        let effectiveCursor = max(0, min(state.cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else {
            state.matches = []
            state.activeIndex = 0
            return
        }

        if let tag = parsed.tag {
            populateListTagValues(tag, partial: parsed.partial, in: query)
            return
        }

        if !parsed.partial.isEmpty {
            showAllUnusedKeys(in: query, partial: parsed.partial)
            return
        }

        state.matches = []
        state.activeIndex = 0
    }

    @discardableResult
    private func requestListSuggestions() -> Bool {
        if store.regexMode { return false }
        let query = store.searchQuery
        let effectiveCursor = max(0, min(state.cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else {
            showAllUnusedKeys(in: query)
            return !state.matches.isEmpty
        }

        if let tag = parsed.tag {
            populateListTagValues(tag, partial: parsed.partial, in: query)
            return !state.matches.isEmpty
        } else {
            showAllUnusedKeys(in: query, partial: parsed.partial)
            return !state.matches.isEmpty
        }
    }

    private func populateListTagValues(_ tag: String, partial: String, in query: String) {
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
                    let k = canonicalListTagName(String(tok[..<colon]).lowercased())
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
            candidates = store.collections.map { col in
                Candidate(
                    key: col.name,
                    display: col.name,
                    subtitle: col.description ?? "Collection",
                    icon: "folder",
                    count: 0
                )
            }

        case "type":
            candidates = ItemType.allCases.map { itemType in
                let keyName = itemType == .url ? "url" : itemType.rawValue
                let count = store.items.filter { $0.type == itemType }.count
                return Candidate(
                    key: keyName,
                    display: keyName,
                    subtitle: itemType.tooltip,
                    icon: itemType.icon,
                    count: count
                )
            }

        case "is":
            let seenIDs = store.seenItemIDs
            candidates = [
                Candidate(key: "recipe", display: "recipe", subtitle: "Items with recipe cards or #recipe", icon: "fork.knife", count: store.items.filter(\.isRecipe).count),
                Candidate(key: "unread", display: "unread", subtitle: "Unseen items", icon: "circle.fill", count: store.items.filter { !seenIDs.contains($0.id) }.count),
                Candidate(key: "starred", display: "starred", subtitle: "Starred items (#fav)", icon: "star.fill", count: store.items.filter { $0.tags?.contains(where: { $0.name.lowercased() == "fav" }) ?? false }.count),
                Candidate(key: "located", display: "located", subtitle: "Geotagged items", icon: "mappin.and.ellipse", count: store.items.filter { $0.location != nil }.count),
                Candidate(key: "annotated", display: "annotated", subtitle: "Items with notes", icon: "note.text", count: store.items.filter { !($0.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count),
                Candidate(key: "archived", display: "archived", subtitle: "Archived items", icon: "archivebox", count: 0)
            ]

        default:
            state.matches = []
            state.activeIndex = 0
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

        state.matches = filtered.map { c in
            let safeKey = (c.key.contains(" ") || c.key.contains(",")) ? "\"\(c.key)\"" : c.key
            return TagSuggestionState.Suggestion(
                id: "val:\(tag):\(c.key.lowercased())",
                label: "\(tag):\(safeKey)",
                display: "\(tag):\(c.display)",
                subtitle: c.subtitle,
                icon: c.icon,
                count: c.count
            )
        }
        state.activeIndex = 0
    }

    private func completeSuggestion(_ label: String) {
        let query = store.searchQuery
        let effectiveCursor = max(0, min(state.cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else { return }

        let trailingSpace = label.hasSuffix(":") ? "" : " "
        var newQuery = query
        newQuery.replaceSubrange(parsed.range, with: label + trailingSpace)

        state.lastSetQuery = newQuery
        store.searchQuery = newQuery

        let prefix = query[query.startIndex..<parsed.range.lowerBound]
        let newCursor = prefix.count + label.count + trailingSpace.count
        pendingCursor = newCursor
        state.cursorLocation = newCursor

        state.matches = []
        state.activeIndex = 0

        if label.hasSuffix(":") {
            let tag = canonicalListTagName(String(label.dropLast()))
            populateListTagValues(tag, partial: "", in: newQuery)
        } else {
            store.debouncedRefresh()
        }
    }

    private func tabInsertSingle(_ label: String) {
        let query = store.searchQuery
        let effectiveCursor = max(0, min(state.cursorLocation, query.count))
        guard let parsed = parseToken(at: effectiveCursor, in: query) else { return }

        var newQuery = query
        newQuery.replaceSubrange(parsed.range, with: label)

        state.lastSetQuery = newQuery
        store.searchQuery = newQuery

        let prefix = query[query.startIndex..<parsed.range.lowerBound]
        let newCursor = prefix.count + label.count
        pendingCursor = newCursor
        state.cursorLocation = newCursor

        if let newParsed = parseToken(at: newCursor, in: newQuery) {
            if let tag = newParsed.tag {
                populateListTagValues(tag, partial: newParsed.partial, in: newQuery)
            } else {
                showAllUnusedKeys(in: newQuery, partial: newParsed.partial)
            }
        } else {
            state.matches = []
        }
    }

    private func handleKey(_ key: SuggestKey) -> Bool {
        switch key {
        case .tab, .shiftTab:
            if state.matches.isEmpty {
                let opened = requestListSuggestions()
                if opened && key == .shiftTab {
                    state.activeIndex = max(0, state.matches.count - 1)
                }
                return true
            }
            if state.matches.count == 1 && key == .tab {
                tabInsertSingle(state.matches[0].label)
                return true
            }
            advance(key == .tab ? .down : .up)
            return true
        case .arrowDown, .ctrlJ:
            if state.matches.isEmpty { return false }
            advance(.down)
            return true
        case .arrowUp, .ctrlK:
            if state.matches.isEmpty { return false }
            advance(.up)
            return true
        case .enter:
            if !state.matches.isEmpty {
                let idx = max(state.activeIndex, 0)
                if idx < state.matches.count {
                    completeSuggestion(state.matches[idx].label)
                }
                return true
            }
            return false  // fall through to FilterField.onSubmit
        case .escape:
            if !state.matches.isEmpty {
                state.matches = []
                state.activeIndex = 0
                return true
            }
            if !store.searchQuery.isEmpty {
                store.searchQuery = ""
                state.cursorLocation = 0
                store.refresh()
                return true
            }
            return false
        }
    }

    private enum Direction { case up, down }

    private func advance(_ direction: Direction) {
        guard !state.matches.isEmpty else { return }
        switch direction {
        case .down: state.activeIndex = (state.activeIndex + 1) % state.matches.count
        case .up:   state.activeIndex = (state.activeIndex - 1 + state.matches.count) % state.matches.count
        }
    }

    // MARK: - Drag-and-drop / multi-row context menu

    /// Pure builder: comma-joined id list for the drag payload. If
    /// the row is in a multi-selection, emit every selected id;
    /// otherwise emit just the one. SidebarView's tag rows split on
    /// comma when receiving so a sidebar-tag drop applies to the
    /// whole batch. Side-effect free — safe to call from view body
    /// recomputation paths.
    private func dragIDs(for itemID: String) -> Set<String> {
        let selected = store.selectedItems
        if selected.contains(itemID) && selected.count > 1 {
            return selected
        }
        return [itemID]
    }

    /// Pure: comma-joined ids for `.draggable(_:)`. No side effects
    /// so the modifier's autoclosure-on-mouseDown invocation doesn't
    /// trigger anything. Sidebar drop targets split this on `,`.
    ///
    /// (Earlier passes tried to put the sidebar grey-out side effect
    /// in this helper, but `.draggable` invokes the autoclosure on
    /// mouseDown — before SwiftUI knows whether an actual drag will
    /// happen. Tracking grey-out reliably needs a different signal;
    /// that feature is parked until we have one.)
    private func dragString(for itemID: String) -> String {
        dragIDs(for: itemID).joined(separator: ",")
    }

    /// The list row's right-click menu, branched on whether the row
    /// is part of a multi-selection. Single-row clicks act on that
    /// row only; multi-row clicks offer "act on all selected" verbs
    /// for the destructive operations. "Tags…" opens a popover
    /// anchored to the right-clicked row in either mode.
    @ViewBuilder
    private func itemContextMenu(rightClickedID: String, inGridView: Bool = false) -> some View {
        let selected = store.selectedItems
        let isMulti = selected.contains(rightClickedID) && selected.count > 1

        if isMulti {
            Text("\(selected.count) items selected")
                .foregroundStyle(.secondary)
            Divider()
            Button("Tags…") {
                showTagPicker(forRowID: rightClickedID, itemIDs: Array(selected))
            }
            // Bulk thumbnail fetch — grid only because thumbnails are
            // the whole point of grid view; surfacing it in list view
            // (which doesn't show thumbnails on rows) reads as
            // misplaced. Each item's type picks its own path:
            // URLs go through importThumbnail, image/file types
            // through generateThumbnail. Snippet/email items skip.
            if inGridView {
                let thumbable = thumbnailCapableIDs(in: Array(selected))
                if !thumbable.isEmpty {
                    Divider()
                    Button("Fetch Thumbnails (\(thumbable.count))") {
                        fetchThumbnails(forIDs: thumbable)
                    }
                }
            }
            Divider()
            Button("Share \(selected.count) Item\(selected.count == 1 ? "" : "s")…") {
                shareItems(ids: Array(selected))
            }
            Button("Export Selected (\(selected.count))…") {
                exportSelection(ids: Array(selected))
            }
            // Merge — fold N-1 of the selected items into the Nth.
            // Most useful for the duplicate-Canna-Lily case: user
            // selects both copies and merges them into a single item
            // whose carousel holds both photos. Picker UI lives in
            // MergeItemsSheet which lets the user pick which copy
            // is the keeper before committing.
            if selected.count >= 2 {
                Divider()
                Button("Merge Selected (\(selected.count))…") {
                    mergeRequest = MergeRequest(itemIDs: Array(selected))
                }
                if selected.count == 2 {
                    let otherID = selected.first { $0 != rightClickedID }!
                    Button("Link Selected Items…") {
                        linkRequest = LinkRequest(sourceID: rightClickedID, targetID: otherID)
                    }
                }
            }
            Divider()
            let isArchivedSection = store.navigation == .archive
            Button(isArchivedSection ? "Unarchive \(selected.count) Items" : "Archive \(selected.count) Items") {
                if isArchivedSection {
                    store.unarchiveItems(ids: Array(selected))
                } else {
                    store.archiveItems(ids: Array(selected))
                }
            }
            Button("Delete \(selected.count) Items…", role: .destructive) {
                store.deleteItems(ids: Array(selected))
            }
        } else {
            Button("Open") { store.openItem(id: rightClickedID) }
            Button("Edit...") {
                store.selectedItemID = rightClickedID
                showEditSheet = true
            }
            Button("Tags…") {
                showTagPicker(forRowID: rightClickedID, itemIDs: [rightClickedID])
            }
            // "Fetch Files from URL…" — only on URL items with a real
            // URL value. Posts the same notification as the toolbar /
            // detail-pane button, with the item's URL as the seed so
            // FetchURLSheet auto-runs Discover on appear.
            if let item = store.items.first(where: { $0.id == rightClickedID }),
               item.type == .url,
               let url = item.url, !url.isEmpty {
                Button("Fetch Files from URL…") {
                    NotificationCenter.default.post(
                        name: .stashOpenFetchURL,
                        object: nil,
                        userInfo: ["url": url]
                    )
                }
            }
            if let item = store.items.first(where: { $0.id == rightClickedID }),
               (item.type == .url || item.type == .snippet || item.isRecipe) {
                Button(item.recipe != nil ? "Re-extract Recipe Card" : "Extract Recipe Card") {
                    Task {
                        _ = await store.extractRecipeForItem(item, prefs: aiPrefs)
                    }
                }
            }
            // Per-item thumbnail action — branch on type so the
            // right verb shows up. Skipped entirely for snippet /
            // email items (no thumbnail concept). Grid only —
            // see the multi-select branch above for rationale.
            if inGridView, let item = store.items.first(where: { $0.id == rightClickedID }) {
                singleItemThumbnailMenu(for: item)
            }
            // Identify with the active AI provider — image items
            // only, key configured. Menu label tracks the picker in
            // Settings → AI so the user sees which backend will run.
            if aiPrefs.hasKey,
               let item = store.items.first(where: { $0.id == rightClickedID }),
               item.type == .image {
                Button("Identify with \(aiPrefs.activeProvider.displayName)") {
                    store.identifyImageItem(id: rightClickedID, with: aiPrefs)
                }
            }
            if aiPrefs.hasKey,
               let item = store.items.first(where: { $0.id == rightClickedID }),
               item.type == .file,
               let mime = item.mimeType, (isAudioMIME(mime) || mime.hasPrefix("video/")) {
                let isVideo = mime.hasPrefix("video/")
                Button(isVideo ? (aiPrefs.fullVideoTranscription ? "Analyze Video (Full)" : "Transcribe Video (Audio Only)") : "Transcribe with \(aiPrefs.activeProvider.displayName)") {
                    store.transcribeMediaItem(id: rightClickedID, with: aiPrefs, fullVideo: aiPrefs.fullVideoTranscription)
                }
            }
            Divider()
            Button("Share…") {
                shareItems(ids: [rightClickedID])
            }
            Button("Export…") {
                exportSelection(ids: [rightClickedID])
            }
            Divider()
            let isArchived = store.items.first(where: { $0.id == rightClickedID })?.archived == true || store.navigation == .archive
            Button(isArchived ? "Unarchive" : "Archive") {
                if isArchived {
                    store.unarchiveItems(ids: [rightClickedID])
                } else {
                    store.archiveItems(ids: [rightClickedID])
                }
            }
            Button("Delete", role: .destructive) {
                store.deleteItem(id: rightClickedID)
            }
        }
    }

    /// Show the macOS Share Sheet seeded with `SharePayload.build`
    /// for the given items. Anchored to the key window since
    /// context menus aren't bound to a SwiftUI view.
    private func shareItems(ids: [String]) {
        let items = store.items.filter { ids.contains($0.id) }
        let payload = SharePayload.build(for: items)
        guard !payload.isEmpty else {
            NSSound.beep()
            return
        }
        let picker = NSSharingServicePicker(items: payload)
        if let window = NSApp.keyWindow,
           let content = window.contentView {
            let anchor = NSRect(
                x: content.bounds.midX - 1,
                y: content.bounds.midY - 1,
                width: 2,
                height: 2
            )
            picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        }
    }

    /// Surface a Save panel and kick off `stash export` with the
    /// selected IDs. Default filename is `stash-export-N-items-DATE.zip`
    /// for multi-select, `stash-export-<title-slug>-DATE.zip` for
    /// single-item exports so the file is identifiable in Finder.
    private func exportSelection(ids: [String]) {
        let label: String
        if ids.count == 1, let item = store.items.first(where: { $0.id == ids[0] }) {
            label = item.title
        } else {
            label = "\(ids.count)-items"
        }
        let suggested = ExportPanels.suggestedFilename(forScopeLabel: label)
        guard let outPath = ExportPanels.chooseExportDestination(suggestedName: suggested) else {
            return
        }
        store.exportItems(scope: .ids(ids), to: outPath)
    }

    /// Per-type thumbnail action button for the single-row grid
    /// context menu. URLs import a thumbnail from the page; image/
    /// file items generate one from local content. Snippet/email
    /// items emit nothing — surfacing a thumbnail action for those
    /// would just be a dead command.
    @ViewBuilder
    private func singleItemThumbnailMenu(for item: StashItem) -> some View {
        switch item.type {
        case .url:
            Divider()
            Button(item.thumbnailPath == nil ? "Import Thumbnail" : "Re-import Thumbnail") {
                store.importThumbnail(itemID: item.id)
            }
        case .image, .file, .audio:
            Divider()
            if store.generatingThumbnailIDs.contains(item.id) {
                Text("Generating...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else {
                Button(item.thumbnailPath == nil ? "Generate Thumbnail" : "Regenerate Thumbnail") {
                    Task {
                        try? await store.generateThumbnailAwaitable(for: item)
                    }
                }
            }
        case .snippet, .email:
            EmptyView()
        }
    }

    /// Filters a multi-select id set to just the items whose type
    /// supports any thumbnail-fetch path. Snippet / email items
    /// drop out so the bulk count reflects what will actually be
    /// dispatched.
    private func thumbnailCapableIDs(in ids: [String]) -> [String] {
        ids.filter { id in
            guard let item = store.items.first(where: { $0.id == id }) else { return false }
            switch item.type {
            case .url, .image, .file, .audio: return true
            case .snippet, .email:    return false
            }
        }
    }

    /// Bulk dispatcher — runs sequentially in a single Task so the
    /// CLI subprocess and SQLite writes don't pile up, and so we can
    /// build a per-item success/failure summary at the end. The old
    /// fire-and-forget loop spawned N concurrent Tasks; each failure
    /// overwrote the next via store.error and the user only ever saw
    /// one. This path tallies and surfaces the count + failed titles.
    private func fetchThumbnails(forIDs ids: [String]) {
        let candidates: [StashItem] = ids.compactMap { id in
            store.items.first(where: { $0.id == id })
        }.filter { item in
            switch item.type {
            case .url, .image, .file, .audio: return true
            case .snippet, .email:    return false
            }
        }
        guard !candidates.isEmpty else { return }
        Task { @MainActor in
            var success = 0
            var failures: [(title: String, error: String)] = []
            for item in candidates {
                do {
                    switch item.type {
                    case .url:
                        try await store.importThumbnailAwaitable(itemID: item.id)
                    case .image, .file, .audio:
                        try await store.generateThumbnailAwaitable(for: item)
                    case .snippet, .email:
                        continue
                    }
                    success += 1
                } catch {
                    failures.append((item.title, error.localizedDescription))
                }
            }
            if !failures.isEmpty {
                let preview = failures.prefix(3).map { $0.title }.joined(separator: ", ")
                let suffix = failures.count > 3 ? " (+\(failures.count - 3) more)" : ""
                store.error = "Fetched \(success) of \(candidates.count) thumbnails. Failed: \(preview)\(suffix)"
            }
        }
    }

    /// Capture the current tag baseline (intersection of tags across
    /// all target items) and show the popover anchored to
    /// `rowID`. Deferred one runloop tick because the contextMenu
    /// hasn't fully dismissed yet — presenting a popover too early
    /// can race the menu's teardown and the popover never paints.
    private func showTagPicker(forRowID rowID: String, itemIDs: [String]) {
        let initial = computeCommonTags(itemIDs: itemIDs)
        DispatchQueue.main.async {
            tagPickerTarget = TagPickerTarget(
                id: rowID,
                itemIDs: itemIDs,
                initialTags: initial
            )
        }
    }

    /// Intersection of tags across the given items — only tags that
    /// every item in the set carries. Toggling such a tag off in the
    /// picker removes it from all selected items; toggling a new tag
    /// on adds it to all of them.
    /// Items the spacebar QuickLook should preview. When a multi-row
    /// selection is active, all selected rows preview together so the
    /// user can arrow through them in the panel. With single or no
    /// selection, falls back to the focused detail row.
    private func quickLookTargets() -> [StashItem] {
        if store.selectedItems.count > 1 {
            let bySelection = store.items.filter { store.selectedItems.contains($0.id) }
            if !bySelection.isEmpty { return bySelection }
        }
        if let focused = store.selectedItem { return [focused] }
        return []
    }

    private func computeCommonTags(itemIDs: [String]) -> Set<String> {
        var common: Set<String>?
        for id in itemIDs {
            guard let item = store.items.first(where: { $0.id == id }) else { continue }
            let tags = Set(item.tagNames)
            if let existing = common {
                common = existing.intersection(tags)
            } else {
                common = tags
            }
        }
        return common ?? []
    }
}

/// Intercepts Tab, Shift-Tab, Ctrl-J/K, arrows, Enter, and Escape in the
/// search field and routes them through the shared `TagSuggestionState`.
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
                // Only forward Tab / Arrow / Enter to the items-list
                // search's tag-cycler when ITS field is focused.
                // Without this guard, focus in any other NSTextView
                // (the detail-pane tag input, the title inline editor,
                // a sheet's FilterField) would hijack those keys into
                // the items-list autocomplete and yank focus visually.
                let focused = MainActor.assumeIsolated { state.isSearchFocused }
                guard focused else { return event }

                let ctrl = event.modifierFlags.contains(.control)
                let shift = event.modifierFlags.contains(.shift)
                let char = event.charactersIgnoringModifiers
                let keyCode = event.keyCode

                let key: SuggestKey?
                switch keyCode {
                case 48:  key = shift ? .shiftTab : .tab            // Tab
                case 125: key = .arrowDown                          // ↓
                case 126: key = .arrowUp                            // ↑
                case 36:  key = .enter                              // Return
                case 53:  key = .escape                             // Esc
                default:
                    if ctrl && char == "j" { key = .ctrlJ }
                    else if ctrl && char == "k" { key = .ctrlK }
                    else { key = nil }
                }

                guard let key else { return event }
                let consumed = MainActor.assumeIsolated { state.onKey?(key) ?? false }
                return consumed ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

// MARK: - Helpers

extension ItemListView {
    /// DFS the view hierarchy for the search field (a NoAutoFillTextField
    /// whose placeholder starts with "Search").
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
}

/// Adds a `.dropDestination` to a list row that, when in collection
/// navigation, calls back into the store to reorder the curated
/// collection so dropped ids land just before this row's item.
/// Reads the store from the environment to avoid wiring a callback
/// through every layer of the row composition.
private struct CollectionRowReorderModifier: ViewModifier {
    @Environment(StashStore.self) private var store
    let enabled: Bool
    let targetID: String
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if enabled {
            content
                // Top-edge insertion bar — same idea as the masonry
                // tile: shows "drop will land here, before this row"
                // without flooding the whole row with a highlight.
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .opacity(isTargeted ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.1), value: isTargeted)
                .dropDestination(for: String.self) { payloads, _ in
                    let ids = Set(
                        payloads
                            .flatMap { $0.split(separator: ",").map(String.init) }
                            .filter { !$0.isEmpty }
                    )
                    guard !ids.isEmpty else { return false }
                    store.reorderCollectionInsertBefore(
                        droppedIDs: ids,
                        targetID: targetID
                    )
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

struct TypeChipView: View {
    let label: String
    let icon: String
    let tooltip: String
    let value: ItemType?
    let selectedValue: ItemType?
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        let selected = selectedValue == value
        Button {
            onSelect()
        } label: {
            HStack(spacing: 4) {
                if isHovering || selected {
                    Text(label)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                
                Image(systemName: icon)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .stroke(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
            // Ensure the parent stretches nicely with the animation
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .help(tooltip)
    }
}
