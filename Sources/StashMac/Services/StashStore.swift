import SwiftUI

@Observable
@MainActor
final class StashStore {
    var items: [StashItem] = []
    var tags: [StashTag] = []
    var collections: [StashCollection] = []

    /// Inbox state — feed candidates pulled from watched sources, the
    /// "to read & watch" queue (items tagged read-later / watch-later),
    /// and the resurface picks computed from forgotten stash items.
    /// All three sections of the Inbox scene read from these arrays.
    var feedCandidates: [FeedCandidate] = []
    var queueItems: [StashItem] = []
    var resurfaceItems: [StashItem] = []
    /// Mirror of the InboxView's highlighted row so the detail pane
    /// (`InboxDetailView`) can render a preview without sharing state
    /// directly across NavigationSplitView columns. At most one is
    /// non-nil at a time; both nil = nothing selected (empty inbox).
    var inboxSelectedCandidate: FeedCandidate?
    var inboxSelectedResurfaceItem: StashItem?
    /// Wall-clock of the last successful feed poll. Drives "Last
    /// polled X min ago" in the Inbox header.
    var lastFeedPoll: Date?
    /// In-app polling timer interval. Sourced from UserDefaults so
    /// the user can change it in Settings; default 30 minutes when
    /// unset. 0 means "never poll from the app" (use Runbook instead).
    private var feedPollTimer: Timer?

    var searchQuery = ""
    var filterType: ItemType?
    var filterTags: Set<String> = []
    var filterCollection: String?
    enum SortMode: String, CaseIterable {
        /// Curated: items use the order returned by the CLI as-is.
        /// For collections the CLI returns ic.position-ordered rows
        /// (the user's drag-and-drop order); for other navigation
        /// it's the same as newest-first since that's the CLI
        /// default. Default sort when entering a collection.
        case curated = "Curated"
        case newestFirst = "Newest"
        case oldestFirst = "Oldest"
        case titleAZ = "Title A-Z"
        case titleZA = "Title Z-A"

        var next: SortMode {
            let all = SortMode.allCases
            let idx = all.firstIndex(of: self)!
            return all[(idx + 1) % all.count]
        }

        var icon: String {
            switch self {
            case .curated: return "hand.draw"
            case .newestFirst: return "chevron.down"
            case .oldestFirst: return "chevron.up"
            case .titleAZ: return "textformat.abc"
            case .titleZA: return "textformat.abc"
            }
        }
    }

    var sortMode: SortMode = .newestFirst

    enum ViewMode: String, CaseIterable {
        case list, grid
    }

    /// List-vs-grid layout for the main pane. Persisted to
    /// UserDefaults so the choice survives relaunches. Pinterest-y
    /// grid mode is the natural surface for browsing thumb-rich
    /// collections (e.g. saved recipe images, leather-craft photos);
    /// the default stays `.list` to match the existing UX.
    var viewMode: ViewMode = {
        if let raw = UserDefaults.standard.string(forKey: "stashViewMode"),
           let mode = ViewMode(rawValue: raw) {
            return mode
        }
        return .list
    }() {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "stashViewMode")
        }
    }

    func toggleViewMode() {
        viewMode = viewMode == .list ? .grid : .list
    }

    var tagGraphData: TagGraphData?
    var savedSearches: [SavedSearch] = []
    var dupeResults: [DupeResult] = []
    var isDupeRunning = false
    var statsData: StashStatsResponse?
    var checkResult: CheckResult?
    var isCheckRunning = false
    var selectedItems: Set<String> = []

    /// True while the user is drag-and-dropping item rows / tiles.
    /// Set by the drag-payload closure on the source side and
    /// cleared by a one-shot `leftMouseUp` event monitor. The
    /// sidebar reads this to grey out drop targets that don't
    /// accept items (Tools, Rules, Tags, Smart Collections, …) so
    /// the valid targets (Static Collections, Tags) visually stand
    /// out during a drag.
    var isDraggingItems = false
    /// IDs of the items currently being dragged. Set on drag start
    /// from the source side; cleared on `endDragTracking`. The
    /// masonry view reads this to compute a live drop-preview that
    /// reflows surrounding tiles to show the proposed placement.
    var draggingItemIDs: Set<String> = []
    private var dragMouseUpMonitor: Any?

    private var dragEndPollTimer: Timer?
    /// Tracks whether mouseDown occurred in the items pane — the
    /// prerequisite for "this might become an item drag." First
    /// `.leftMouseDragged` after arming flips the drag-tracking flag;
    /// a plain click clears it on mouseUp without ever flipping.
    private var dragArmed = false
    private var dragMonitor: Any?


    /// Install the mouse-event monitor that drives the sidebar
    /// grey-out cue. `.draggable`'s autoclosure fires on mouseDown
    /// (before we know whether a drag will actually happen), and
    /// `.onDrag` doesn't compose with `.draggable`, so we observe
    /// the raw event stream and decide ourselves: a drag is in
    /// progress when the mouse moved past a threshold while a
    /// selection existed at mouseDown time. Idempotent — called by
    /// `ItemListView.onAppear`.
    func installItemDragMonitor() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                // Double-click on a row: open the item in its default
                // app. We do this at the AppKit level because SwiftUI's
                // `.onTapGesture(count: 2)` either misses non-hittable
                // child views (text/tags) or captures single clicks
                // during its tap-count window (breaking row selection
                // and drag). `event.clickCount == 2` is reliable and
                // doesn't interfere.
                //
                // Scope: only fire when (a) a row is currently focused
                // (`selectedItemID` is set, meaning the prior tap-1
                // selected a row in the items list), and (b) no text
                // field has key focus (a double-click in the filter
                // field is "select word", not "open item").
                if event.clickCount == 2,
                   let id = self.selectedItemID,
                   !Self.aTextFieldHasFocus(in: event.window),
                   Self.clickIsInItemsList(event) {
                    Task { @MainActor in self.openItem(id: id) }
                }
                // mouseDown is an unambiguous "new user gesture starting"
                // signal that arrives BEFORE AppKit's drag-and-drop loop
                // hijacks the event stream. If we still think a drag is
                // in progress here, the previous drag's mouseUp was
                // swallowed by AppKit's tracking loop and our 200ms
                // polling timer hasn't fired yet — that's the stale-
                // state leak that caused the next single-row drag to
                // skip `beginDragTracking` (guard `!isDraggingItems`)
                // and inherit the prior drag's `draggingItemIDs`.
                if self.isDraggingItems {
                    Task { @MainActor in self.endDragTracking() }
                }
                self.dragArmed = true
            case .leftMouseDragged:
                // First mouseDragged after arming is enough to flip the
                // grey-out flag — we don't accumulate distance any more
                // because SwiftUI's `.draggable` hands off to AppKit's
                // drag session after only 2–3 pixels of movement on
                // single-row drags, before a 6-pixel accumulator could
                // possibly trip. False-positives from click-jitter are
                // cleared on mouseUp (or 200ms later via the poll
                // timer if AppKit ate the mouseUp).
                guard self.dragArmed, !self.isDraggingItems else { break }
                // Capture the selection snapshot now; the dragged set
                // is empty for an unselected-row drag (the `.draggable`
                // payload uses the row's own id directly), which is
                // fine — only the grey-out flag matters for sidebar
                // dim-out, and `draggingItemIDs` is consumed only by
                // the masonry-grid drop preview which falls back
                // gracefully when empty.
                let ids = self.selectedItems
                Task { @MainActor in self.beginDragTracking(ids: ids) }
            case .leftMouseUp:
                self.dragArmed = false
                // isDraggingItems is cleared either here implicitly
                // (when AppKit lets us see the mouseUp — i.e. no real
                // drag started) by the timer, or proactively on the
                // next mouseDown if AppKit's drag loop swallowed it.
                if self.isDraggingItems {
                    Task { @MainActor in self.endDragTracking() }
                }
            default:
                break
            }
            return event
        }
    }

    /// True if the mouseDown event landed on something inside the
    /// items list (an `NSTableView` ancestor). Used to gate the
    /// AppKit-level double-click → `openItem` path so a double-click
    /// in the detail pane (e.g. on Notes) doesn't silently launch
    /// Preview.app for the currently selected item. Uses AppKit
    /// hit-testing rather than tracking a SwiftUI frame because any
    /// SwiftUI overlay added for frame tracking risks intercepting
    /// list clicks (icon-tap thumbnail popover, drag-arming).
    private static func clickIsInItemsList(_ event: NSEvent) -> Bool {
        guard let hit = event.window?.contentView?.hitTest(event.locationInWindow) else {
            return false
        }
        var v: NSView? = hit
        while let cur = v {
            if cur is NSTableView { return true }
            v = cur.superview
        }
        return false
    }

    /// True when a text field (or its field editor) is the first
    /// responder of `window` (or the key window when nil). Used to
    /// gate AppKit-level double-click → openItem so we don't open the
    /// focused row when the user is double-clicking inside the filter
    /// field to select a word.
    private static func aTextFieldHasFocus(in window: NSWindow?) -> Bool {
        let target = window ?? NSApp.keyWindow
        guard let responder = target?.firstResponder else { return false }
        if responder is NSTextField { return true }
        // Field editor case — NSTextView whose delegate is the
        // owning NSTextField.
        if let editor = responder as? NSText, editor.delegate is NSTextField {
            return true
        }
        return false
    }

    func removeItemDragMonitor() {
        if let m = dragMonitor {
            NSEvent.removeMonitor(m)
            dragMonitor = nil
        }
        dragArmed = false
    }

    func beginDragTracking(ids: Set<String> = []) {
        draggingItemIDs = ids
        if isDraggingItems { return }
        isDraggingItems = true

        // Poll `NSEvent.pressedMouseButtons` (system mouse state) for
        // drag-end. AppKit's drag-and-drop loop runs the runloop in
        // `.eventTracking` mode and swallows leftMouseUp before any
        // local NSEvent monitor sees it, so the previous monitor
        // approach left the grey-out stuck after cancelled drags.
        // Critically, the timer must be added in `.common` modes —
        // `.scheduledTimer` defaults to `.default`, which is paused
        // during the drag loop.
        dragEndPollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            timer.invalidate()
            Task { @MainActor in self?.endDragTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragEndPollTimer = timer
    }

    func endDragTracking() {
        isDraggingItems = false
        draggingItemIDs = []
        dragEndPollTimer?.invalidate()
        dragEndPollTimer = nil
        if let m = dragMouseUpMonitor {
            NSEvent.removeMonitor(m)
            dragMouseUpMonitor = nil
        }
    }
    var navigation: NavigationItem? = StashStore.initialNavigation() {
        didSet {
            if let nav = navigation {
                UserDefaults.standard.set(nav.persistenceKey, forKey: "stashNavigation")
            }
        }
    }
    /// One-shot signal set on first launch and consumed by
    /// `loadAll()` after the lookup arrays (tags/collections/saved
    /// searches) are populated. Only set for parameterized cases
    /// (tag/collection/savedSearch/type) that can't be resolved
    /// until the CLI lookups finish — top-level cases are restored
    /// eagerly in `initialNavigation()` so there's no flash.
    private var pendingRestoreNavigationKey: String? = StashStore.initialPendingKey()

    /// Top-level (no-data-needed) cases are restored eagerly here so
    /// the user lands on the section they quit from without a flash
    /// of All Items first. Parameterized cases (tag/collection/
    /// savedSearch/type) return `.allItems` here and rely on
    /// `loadAll()` to upgrade once the lookup arrays are populated.
    private static func initialNavigation() -> NavigationItem {
        guard let key = UserDefaults.standard.string(forKey: "stashNavigation") else {
            return .allItems
        }
        // Resolve without lookup data; only top-level cases succeed.
        if let nav = NavigationItem.from(
            persistenceKey: key,
            tags: [],
            collections: [],
            savedSearches: []
        ) {
            return nav
        }
        return .allItems
    }

    /// Returns the persisted key only when it references a
    /// parameterized case that requires lookup data. Eagerly-
    /// resolvable keys are already applied in `initialNavigation()`,
    /// so leaving the pending slot empty for those avoids
    /// re-asserting the same value after `loadAll`.
    private static func initialPendingKey() -> String? {
        guard let key = UserDefaults.standard.string(forKey: "stashNavigation") else {
            return nil
        }
        if NavigationItem.from(
            persistenceKey: key,
            tags: [],
            collections: [],
            savedSearches: []
        ) != nil {
            return nil
        }
        return key
    }
    var selectedItemID: String? {
        didSet {
            if let id = selectedItemID {
                markSeen(id)
            }
        }
    }
    /// One-shot signal: when set, ItemListView's ScrollViewReader
    /// scrolls the matching row into view and clears the value.
    /// Cleared instead of left set so the same id can be re-requested
    /// later (e.g. user re-commits the same result from QuickSearch).
    var pendingRevealID: String?
    /// Rules loaded from the CLI. Populated lazily by `loadRules()`; the
    /// rules sidebar entry kicks off the first load. Both `RulesView` (the
    /// list) and `RuleDetailView` (the form) read from this.
    var rules: [Rule] = []
    var rulesLoading = false
    var rulesError: String?
    /// Currently selected rule. Drives `RuleDetailView`. `__new__` is a
    /// sentinel for an unsaved draft created via the "+" button — the
    /// detail pane shows a blank form bound to `draftRule`.
    var selectedRuleName: String?
    /// Working copy for an unsaved new rule. Created when the user clicks
    /// "+" in the rules list. Discarded if the user navigates away
    /// without saving.
    var draftRule: Rule?

    /// Rule activity events loaded from `stash rules log --json`. The
    /// activity view triggers loads with the current filter set and the
    /// store re-reads on `.stashDidIngest` so newly-fired events appear
    /// without manual refresh.
    var ruleEvents: [RuleEvent] = []
    var ruleEventsLoading = false
    var ruleEventsError: String?
    /// Stable id of the selected event in `RuleActivityView`, used to
    /// drive `RuleActivityDetailView` in the right column.
    var selectedRuleEventID: String?
    var isLoading = false
    var error: String?
    var flashMessage: String?
    var seenItemIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "seenItemIDs") ?? [])
    }()

    private let cli = StashCLI.shared
    private var searchTask: Task<Void, Never>?
    private var suppressNavigationChange = false
    private var ingestObserver: NSObjectProtocol?

    var fetchedItem: StashItem?

    init() {
        ingestObserver = NotificationCenter.default.addObserver(
            forName: .stashDidIngest,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleIngest() }
        }
    }

    /// Run an export through the CLI and post the result to the
    /// `lastExportResult` slot for the success banner UI. Errors land
    /// in `self.error` for the standard alert path.
    func exportItems(scope: StashCLI.ExportScope, to outPath: String, includeArchived: Bool = false) {
        Task {
            do {
                let result = try await cli.exportItems(
                    scope: scope,
                    outPath: outPath,
                    includeArchived: includeArchived
                )
                lastExportResult = result
            } catch {
                self.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Holds the most recent successful export so the UI can render
    /// a "Reveal in Finder / Open archive" toast. Cleared by the
    /// banner's dismiss action.
    var lastExportResult: StashCLI.ExportResult?

    /// Run an import through the CLI and refresh the items list on
    /// success so the new rows appear immediately. Errors land in
    /// `self.error`; non-fatal per-item errors are surfaced in the
    /// banner alongside the success count.
    func importArchive(path: String, policy: StashCLI.ImportPolicy = .newID) {
        Task {
            do {
                let summary = try await cli.importArchive(path: path, policy: policy)
                lastImportSummary = summary
                loadAll()
            } catch {
                self.error = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Holds the most recent successful import for the success
    /// banner. Same lifecycle as `lastExportResult`.
    var lastImportSummary: StashCLI.ImportSummary?


    /// Run a `fetch-url --pick` through the CLI and refresh once the
    /// items land. The picker sheet drives the UI; this just wires
    /// the call + post-import reload + error surfacing.
    func fetchURLPick(
        pageURL: String,
        picks: [String],
        linkSource: Bool,
        clique: Bool = false,
        archive: Bool,
        tags: [String],
        collection: String?
    ) async -> StashCLI.FetchURLPickResult? {
        do {
            let result = try await cli.fetchURLPick(
                pageURL: pageURL,
                picks: picks,
                linkSource: linkSource,
                clique: clique,
                archive: archive,
                tags: tags,
                collection: collection
            )
            await MainActor.run { loadAll() }
            return result
        } catch {
            await MainActor.run {
                self.error = "Fetch failed: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Auto-refresh path triggered on every successful capture. If the
    /// user is currently viewing a Smart Collection, re-run that
    /// specifically so the list reflects newly-captured matches without
    /// losing the filter. Otherwise fall back to the generic loadAll()
    /// so other views stay in sync.
    private func handleIngest() {
        if case .savedSearch(let ss) = navigation {
            loadSavedSearches()
            runSavedSearch(name: ss.name)
            return
        }
        loadAll()
    }

    var selectedItem: StashItem? {
        guard let id = selectedItemID else { return nil }
        if let item = items.first(where: { $0.id == id }) { return item }
        return fetchedItem?.id == id ? fetchedItem : nil
    }

    func loadAll() {
        guard !isLoading else { return }
        Task {
            isLoading = true
            error = nil
            do {
                items = try await fetchFilteredItems()
                tags = try await cli.listTags()
                collections = try await cli.listCollections()
                tagGraphData = try await cli.tagGraph()
                savedSearches = try await cli.listSavedSearches()
                applySortMode()
                // Restore the section the user was on at last quit.
                // We do this after the lookup arrays are populated so
                // tag/collection/savedSearch cases can resolve their
                // backing object. One-shot — consume on first run.
                if let key = pendingRestoreNavigationKey {
                    pendingRestoreNavigationKey = nil
                    if let restored = NavigationItem.from(
                        persistenceKey: key,
                        tags: tags,
                        collections: collections,
                        savedSearches: savedSearches
                    ), restored != navigation {
                        navigation = restored
                    }
                }
                // Mark all existing items as seen on first load
                if !UserDefaults.standard.bool(forKey: "initialSeenDone2") {
                    let allItems = try await cli.listItems(limit: 100000)
                    for item in allItems {
                        seenItemIDs.insert(item.id)
                    }
                    UserDefaults.standard.set(Array(seenItemIDs), forKey: "seenItemIDs")
                    UserDefaults.standard.set(true, forKey: "initialSeenDone2")
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    func debouncedRefresh() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func refresh() {
        guard !isLoading else { return }
        Task {
            isLoading = true
            error = nil
            do {
                items = try await fetchFilteredItems()
                applySortMode()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Fetch items honoring the current sidebar filters and search query.
    /// Inline `tag:foo` tokens in the search box are extracted and merged with
    /// the sidebar tag filter. Used by both `refresh()` (items only) and
    /// `loadAll()` (items + tags/collections/saved-searches/graph).
    private func fetchFilteredItems() async throws -> [StashItem] {
        var allTags = Array(filterTags)
        var textQuery = searchQuery

        if !searchQuery.isEmpty {
            let pattern = /tag:(\S+)/
            let inlineMatches = searchQuery.matches(of: pattern)
            allTags += inlineMatches.map { String($0.output.1) }
            textQuery = searchQuery.replacing(/tag:\S*/, with: "").trimmingCharacters(in: .whitespaces)
        }

        if textQuery.isEmpty {
            return try await cli.listItems(
                type: filterType,
                tags: allTags,
                collection: filterCollection,
                limit: 100
            )
        }
        return try await cli.searchItems(
            query: textQuery,
            type: filterType,
            tags: allTags,
            limit: 100
        )
    }

    private func applySortMode() {
        switch sortMode {
        case .curated, .newestFirst:
            // Curated uses the CLI's as-fetched order (ic.position
            // for collections, created_at DESC otherwise). Newest
            // First is the same outside collections; inside them
            // it's effectively redundant with curated for now.
            break
        case .oldestFirst:
            items.reverse()
        case .titleAZ:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleZA:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }

    func cycleSortMode() {
        var next = sortMode.next
        // Skip `.curated` when not in a collection — there it just
        // duplicates `.newestFirst`. Inside a collection, all modes
        // are reachable so users can flip out of curated to scan by
        // date / title and back.
        let inCollection: Bool
        if case .collection = navigation { inCollection = true }
        else { inCollection = false }
        if next == .curated && !inCollection {
            next = next.next
        }
        sortMode = next
        refresh()
    }

    func addURL(url: String, title: String?, tags: [String], note: String?, collection: String?) {
        Task {
            do {
                let item = try await cli.addURL(url: url, title: title, tags: tags, note: note, collection: collection)
                loadAll()
                // Capture-time thumbnail auto-import. Best-effort —
                // failures (no og:image, network hiccup, paywall) are
                // silent; user can re-trigger via the detail view.
                _ = try? await cli.thumbnailImport(id: item.id)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func addFile(path: String, title: String?, tags: [String], note: String?, collection: String?) {
        Task {
            do {
                let item = try await cli.addFile(path: path, title: title, tags: tags, note: note, collection: collection)
                loadAll()
                // Auto-generate a thumbnail for image/file/audio/video
                // captures so the list row and detail block render
                // something useful immediately. URL items wait for
                // Phase 2's HTML extraction.
                if shouldAutoThumbnail(item) {
                    _ = try? await ThumbnailService.shared.generate(for: item)
                    loadAll()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func shouldAutoThumbnail(_ item: StashItem) -> Bool {
        guard item.thumbnailPath == nil else { return false }
        switch item.type {
        case .image, .file: return true
        case .url, .snippet, .email: return false
        }
    }

    func addSnippet(text: String, title: String?, tags: [String], note: String?, collection: String?) {
        Task {
            do {
                _ = try await cli.addSnippet(text: text, title: title, tags: tags, note: note, collection: collection)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func editItem(id: String, title: String?, note: String?, extractedText: String? = nil, url: String? = nil, addTags: [String], removeTags: [String], collection: String?, location: ItemLocation? = nil, clearLocation: Bool = false) {
        // Optimistic update for the Health Check view: the moment a
        // URL edit lands, mark the row as "rechecking" with the new
        // URL so the user gets immediate visual feedback. Without
        // this, the user dismisses the edit sheet, lands back on
        // Health Check, sees the *old* URL, and only after the HTTP
        // recheck completes (1–5s later) does the row update or
        // disappear — easy to miss and reads as a bug.
        if let url, let issues = checkResult?.brokenUrls,
           let idx = issues.firstIndex(where: { $0.id == id }) {
            var current = checkResult ?? CheckResult()
            current.brokenUrls?[idx].detail = "\(url) — rechecking…"
            checkResult = current
        }

        Task {
            do {
                _ = try await cli.editItem(id: id, title: title, note: note, extractedText: extractedText, url: url, addTags: addTags, removeTags: removeTags, collection: collection, location: location, clearLocation: clearLocation)
                loadAll()
                // If the URL changed and an active health check has
                // this item in its broken-URLs list, re-check just
                // this one URL and prune the row if it now responds.
                // Avoids the user editing in the general edit sheet
                // and seeing the row stick around.
                if url != nil, let bru = checkResult?.brokenUrls,
                   bru.contains(where: { $0.id == id }) {
                    await recheckBrokenURLAndPrune(id: id)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Re-check a single broken-URL row on demand. Wired to the
    /// per-row refresh button in the Health Check view so the user
    /// can re-verify a row after editing it (or after fixing the
    /// underlying server) without running the whole check pass.
    /// Uses the same recheckBrokenURLAndPrune path the URL-edit
    /// flow uses, so behavior is consistent.
    func recheckBrokenURL(id: String) {
        Task { await recheckBrokenURLAndPrune(id: id) }
    }

    /// Update only an item's URL — focused entry point for the
    /// Health Check "Edit URL…" workflow. Calls editItem (which
    /// schedules its own recheck), so this is just the convenience
    /// wrapper.
    func updateURL(id: String, url: String) {
        editItem(id: id, title: nil, note: nil, url: url, addTags: [], removeTags: [], collection: nil)
    }

    /// Re-fetch the URL for a single item via `stash check --urls
    /// --id <id>`. Drops the broken-URLs row if the new URL now
    /// responds; otherwise refreshes the row's detail in place so
    /// the user sees the *current* failure mode (e.g. a switch from
    /// DNS error to 404). Cheap (one HTTP request) compared to
    /// running the whole check.
    private func recheckBrokenURLAndPrune(id: String) async {
        do {
            let stillBroken = try await cli.recheckURL(id: id)
            guard var current = checkResult else { return }
            if let issue = stillBroken {
                if let idx = current.brokenUrls?.firstIndex(where: { $0.id == id }) {
                    current.brokenUrls?[idx] = issue
                }
            } else {
                current.brokenUrls?.removeAll { $0.id == id }
            }
            checkResult = current
        } catch {
            // Don't bury the failure — the user just edited the URL
            // and is waiting to see Health Check update. If we can't
            // tell whether the new URL works, mark the row "recheck
            // failed" so the user knows something didn't complete
            // (vs. the row appearing to stick around silently). Next
            // manual Run Check or per-row refresh will resolve it.
            guard var current = checkResult else { return }
            if let idx = current.brokenUrls?.firstIndex(where: { $0.id == id }) {
                let prev = current.brokenUrls?[idx].detail ?? ""
                current.brokenUrls?[idx].detail = "recheck failed: \(error.localizedDescription) — last known: \(prev)"
                checkResult = current
            }
        }
    }

    /// Copy a single field of an item to the system clipboard via
    /// the `stash copy` subcommand. Best-effort — errors land in
    /// `self.error` for the same surfacing as other CLI failures.
    func copyItemField(id: String, field: String) {
        Task {
            do {
                try await cli.copyItemField(id: id, field: field)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func deleteItem(id: String) {
        Task {
            do {
                // Find the next item before deleting
                var nextID: String?
                if selectedItemID == id, let idx = items.firstIndex(where: { $0.id == id }) {
                    if idx + 1 < items.count {
                        nextID = items[idx + 1].id
                    } else if idx > 0 {
                        nextID = items[idx - 1].id
                    }
                }
                try await cli.deleteItem(id: id)
                selectedItemID = nextID
                pruneCheckResult(removingIDs: [id])
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Archive one or more items (soft-delete). Used by Health Check
    /// row context menus and by future bulk operations. Optimistically
    /// removes archived rows from the active health-check result
    /// without re-running the check — re-running re-fetches every URL
    /// in the library, which is expensive. The next manual `Run
    /// Check` is the source of truth.
    func archiveItems(ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await cli.archiveItems(ids: ids)
                if ids.contains(selectedItemID ?? "") { selectedItemID = nil }
                pruneCheckResult(removingIDs: Set(ids))
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Add (or remove) one tag across many items in a single CLI
    /// call. Used by the sidebar drop-destination (drag items onto
    /// a tag row) and the tag-picker popover. Refreshes the items
    /// list so the new tag appears in row chips immediately.
    /// Add a set of items to a named collection in one CLI call. Used by
    /// the sidebar drag-and-drop receiver — drag rows from the list (or
    /// tiles from the grid / masonry) onto a Collection row to add them
    /// all in one go. Items can belong to multiple collections, so this
    /// is purely additive — no implicit removal from any other collection.
    func bulkAddToCollection(ids: [String], collection: String) {
        guard !ids.isEmpty, !collection.isEmpty else { return }
        Task {
            do {
                try await cli.bulkCollect(ids: ids, collection: collection)
                loadAll()
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Reorder a collection by inserting `droppedIDs` immediately
    /// before `targetID` in the current curated order. Used by drag-
    /// to-reorder in the masonry / list view when the user is
    /// navigated to a collection. Optimistic: updates `items`
    /// in-place and persists via the CLI; refreshes from the store
    /// on success so any rule-driven side effects show up.
    func reorderCollectionInsertBefore(droppedIDs: Set<String>, targetID: String?) {
        guard case .collection(let col) = navigation else { return }
        guard !droppedIDs.isEmpty else { return }
        let current = items
        let filtered = current.filter { !droppedIDs.contains($0.id) }
        let droppedItems = current.filter { droppedIDs.contains($0.id) }

        var newOrder: [StashItem] = []
        var inserted = false
        if let targetID, !droppedIDs.contains(targetID) {
            for item in filtered {
                if item.id == targetID && !inserted {
                    newOrder.append(contentsOf: droppedItems)
                    inserted = true
                }
                newOrder.append(item)
            }
        } else {
            newOrder = filtered
        }
        if !inserted {
            newOrder.append(contentsOf: droppedItems)
        }

        let ids = newOrder.map(\.id)
        items = newOrder
        // Clear drag state synchronously so the ghost preview clears
        // the instant the drop fires. Otherwise we wait for the
        // NSEvent leftMouseUp monitor — which AppKit's drag system
        // sometimes consumes during a drop, leaving the ghost
        // styling stuck until the next user click.
        endDragTracking()
        Task {
            do {
                try await cli.collectionReorder(name: col.name, ids: ids)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func bulkAddTag(ids: [String], tag: String) {
        guard !ids.isEmpty, !tag.isEmpty else { return }
        Task {
            do {
                try await cli.bulkTag(ids: ids, addTags: [tag])
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func bulkApplyTagChanges(ids: [String], addTags: [String], removeTags: [String]) {
        guard !ids.isEmpty, !addTags.isEmpty || !removeTags.isEmpty else { return }
        Task {
            do {
                try await cli.bulkTag(ids: ids, addTags: addTags, removeTags: removeTags)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Thumbnails

    /// Auto-generate a thumbnail for the item from its existing
    /// content (file via QuickLook, video via frame grab, audio via
    /// embedded artwork). Surfaces a friendly error when macOS has
    /// no generator for the file type — common for archives — so
    /// the user understands why nothing changed.
    func generateThumbnail(for item: StashItem) {
        Task {
            do {
                try await generateThumbnailAwaitable(for: item)
            } catch ThumbnailService.SourceError.noContent {
                self.error = "macOS can't preview this file type. Use 'Import…' or drop an image to set a thumbnail manually."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Awaitable form of generateThumbnail — used by bulk-fetch
    /// callers that need to know per-item success/failure rather
    /// than relying on the fire-and-forget error binding (which can
    /// only show one error at a time and gets overwritten by
    /// successive failures). Same logic as the fire-and-forget
    /// variant; throws instead of swallowing into self.error.
    func generateThumbnailAwaitable(for item: StashItem) async throws {
        _ = try await ThumbnailService.shared.generate(for: item)
        loadAll()
    }

    /// Set the thumbnail from a user-chosen local file.
    func setThumbnail(itemID: String, fileURL: URL) {
        Task {
            do {
                _ = try await ThumbnailService.shared.setFromFile(fileURL, for: itemID)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Set the thumbnail from a remote image URL.
    func setThumbnail(itemID: String, imageURL: URL) {
        Task {
            do {
                _ = try await ThumbnailService.shared.setFromImageURL(imageURL, for: itemID)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func clearThumbnail(itemID: String) {
        Task {
            do {
                try await ThumbnailService.shared.clear(itemID: itemID)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Import a thumbnail by fetching a URL (defaults to item.url).
    /// Goes through the CLI's `stash thumbnail import` for the HTML
    /// scrape and direct-image branches. If the URL points to a
    /// document type the CLI can't render (PDF, Office, video, …),
    /// fall back to a Mac-side path that downloads the file and uses
    /// QuickLook to make a thumbnail.
    func importThumbnail(itemID: String, from: String? = nil) {
        Task {
            do {
                try await importThumbnailAwaitable(itemID: itemID, from: from)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Awaitable form of importThumbnail — see generateThumbnailAwaitable
    /// for rationale. Routes "unsupported content-type" failures
    /// through the QuickLook fallback the same way the
    /// fire-and-forget variant does, so callers don't have to
    /// reimplement that logic.
    func importThumbnailAwaitable(itemID: String, from: String? = nil) async throws {
        do {
            _ = try await cli.thumbnailImport(id: itemID, from: from)
            loadAll()
        } catch let error as CLIError {
            // Fallback chain when the CLI scrape fails:
            //   - "no thumbnail candidates found" — HTML loaded but
            //     yielded no og:image / twitter:image / in-page <img>.
            //     JS-heavy sites (Amazon product pages, SPAs) hit
            //     this constantly. WKWebView runs the same engine as
            //     Safari and snapshots the rendered viewport, so it
            //     captures what the user actually sees. If WebKit
            //     itself fails (timeout, snapshot null, network
            //     refused), drop through to QuickLook on the raw
            //     HTML as a thinner-but-better-than-nothing last
            //     resort.
            //   - "unsupported content-type" — the URL points at a
            //     non-HTML file (PDF, Office, video, …) that the
            //     scraper can't read but QuickLook can. Skip the
            //     WebKit step here since rendering a non-HTML URL
            //     in WebKit would just download or refuse.
            if case .failed(let msg) = error {
                let lower = msg.lowercased()
                if lower.contains("no thumbnail candidates") {
                    if await tryWebKitFallback(itemID: itemID, from: from) {
                        return
                    }
                    await importViaQuickLookFallback(itemID: itemID, from: from)
                    return
                }
                if lower.contains("unsupported content-type") {
                    await importViaQuickLookFallback(itemID: itemID, from: from)
                    return
                }
            }
            throw error
        }
    }

    /// Try the WKWebView render path. Returns true on success so the
    /// caller can short-circuit further fallbacks; on any error we
    /// log to self.error and return false so the caller can try
    /// QuickLook next.
    private func tryWebKitFallback(itemID: String, from: String?) async -> Bool {
        do {
            let item = try await cli.getItem(id: itemID)
            let urlString = (from?.isEmpty == false ? from! : (item.url ?? ""))
            guard let url = URL(string: urlString), !urlString.isEmpty else {
                return false
            }
            _ = try await ThumbnailService.shared.importViaWebKit(url, for: itemID)
            loadAll()
            return true
        } catch {
            // Don't surface — caller will try QuickLook next, which
            // produces its own error if it also fails.
            return false
        }
    }

    /// Resolve the source URL (explicit `from`, else item.url),
    /// hand it to ThumbnailService.importViaQuickLook for download +
    /// QL rendering, and refresh.
    private func importViaQuickLookFallback(itemID: String, from: String?) async {
        do {
            let item = try await cli.getItem(id: itemID)
            let urlString = (from?.isEmpty == false ? from! : (item.url ?? ""))
            guard let url = URL(string: urlString), !urlString.isEmpty else {
                self.error = "No source URL to fetch"
                return
            }
            _ = try await ThumbnailService.shared.importViaQuickLook(url, for: itemID)
            loadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Bulk delete (permanent). Caller should confirm before invoking.
    /// Same optimistic-prune semantics as `archiveItems`.
    func deleteItems(ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await cli.bulkDelete(ids: ids)
                if ids.contains(selectedItemID ?? "") { selectedItemID = nil }
                pruneCheckResult(removingIDs: Set(ids))
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Remove the given item ids from every list inside the active
    /// `checkResult`. Called after archive/delete/url-fix so the
    /// rows disappear immediately without a full re-check.
    private func pruneCheckResult(removingIDs ids: Set<String>) {
        guard var current = checkResult else { return }
        current.brokenUrls?.removeAll { ids.contains($0.id) }
        current.missingFiles?.removeAll { ids.contains($0.id) }
        if var groups = current.duplicateHashes {
            for i in groups.indices {
                groups[i].items.removeAll { ids.contains($0.id) }
            }
            // Drop dupe groups that no longer have ≥2 members.
            groups.removeAll { $0.items.count < 2 }
            current.duplicateHashes = groups
        }
        checkResult = current
    }

    func refetchURLContent(id: String) {
        Task {
            do {
                _ = try await cli.refreshItem(id: id)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func openItem(id: String) {
        Task {
            do {
                try await cli.openItem(id: id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func linkItems(from: String, to: String, label: String? = nil, directed: Bool = false) {
        Task {
            do {
                try await cli.linkItems(from: from, to: to, label: label, directed: directed)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func unlinkItems(idA: String, idB: String) {
        Task {
            do {
                try await cli.unlinkItems(idA: idA, idB: idB)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func renameTag(old: String, new: String) {
        Task {
            do {
                try await cli.renameTag(old: old, new: new)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func createCollection(name: String, description: String?) {
        Task {
            do {
                _ = try await cli.createCollection(name: name, description: description)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func deleteCollection(name: String) {
        Task {
            do {
                try await cli.deleteCollection(name: name)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Rules

    func loadRules() {
        Task {
            rulesLoading = true
            defer { rulesLoading = false }
            do {
                rules = try await cli.listRules()
                rulesError = nil
            } catch {
                rulesError = error.localizedDescription
            }
        }
    }

    /// Begin a new-rule draft. Sets `draftRule` to a blank Rule and
    /// selects it via the `__new__` sentinel so the detail pane shows the
    /// form. The draft persists across selection changes until saved or
    /// discarded.
    func startNewRuleDraft() {
        let blank = Rule(
            name: "",
            enabled: nil,
            match: RuleMatch(),
            actions: [RuleAction()]
        )
        draftRule = blank
        selectedRuleName = "__new__"
    }

    /// Begin a new-rule draft pre-populated from a Suggest-Rules
    /// proposal. Switches navigation to the Rules section and selects
    /// the draft sentinel so the detail pane immediately shows the
    /// editor with the proposal filled in. Nothing is written to
    /// rules.yaml until the user clicks Create in the editor — Cancel
    /// discards entirely.
    func startRuleDraft(from rule: Rule) {
        draftRule = rule
        selectedRuleName = "__new__"
        navigation = .rules
    }

    func discardDraft() {
        draftRule = nil
        if selectedRuleName == "__new__" {
            selectedRuleName = nil
        }
    }

    func saveRule(_ rule: Rule) {
        Task {
            do {
                try await cli.saveRule(rule)
                rules = try await cli.listRules()
                draftRule = nil
                selectedRuleName = rule.name
                rulesError = nil
            } catch {
                rulesError = "Failed to save \(rule.name): \(error.localizedDescription)"
            }
        }
    }

    func deleteRule(name: String) {
        Task {
            do {
                try await cli.removeRule(name: name)
                rules = try await cli.listRules()
                if selectedRuleName == name { selectedRuleName = nil }
                rulesError = nil
            } catch {
                rulesError = "Failed to delete \(name): \(error.localizedDescription)"
            }
        }
    }

    /// Rename a rule. Re-selects the renamed rule and refreshes the
    /// activity feed so per-rule history stays attached after the log
    /// rewrite. Errors land in `rulesError`.
    func renameRule(oldName: String, newName: String) {
        Task {
            do {
                try await cli.renameRule(oldName: oldName, newName: newName)
                rules = try await cli.listRules()
                if selectedRuleName == oldName {
                    selectedRuleName = newName
                }
                // Reload activity so any open feed picks up the rewritten
                // rule names.
                loadRuleEvents()
                rulesError = nil
            } catch {
                rulesError = "Failed to rename \(oldName) → \(newName): \(error.localizedDescription)"
            }
        }
    }

    /// Load activity-log events with the given filters. `since` accepts
    /// the same syntax as `stash rules log --since` (`30m`, `1h`, `7d`,
    /// `1w`). Errors land in `ruleEventsError` so the view can surface
    /// them without crashing.
    func loadRuleEvents(
        type: RuleEvent.EventType? = nil,
        rule: String? = nil,
        since: String? = nil,
        limit: Int = 200
    ) {
        Task {
            ruleEventsLoading = true
            defer { ruleEventsLoading = false }
            do {
                ruleEvents = try await cli.listRuleEvents(
                    type: type, rule: rule, limit: limit, since: since
                )
                ruleEventsError = nil
            } catch {
                ruleEventsError = error.localizedDescription
            }
        }
    }

    func setRuleEnabled(name: String, enabled: Bool) {
        Task {
            do {
                try await cli.setRuleEnabled(name: name, enabled: enabled)
                if let idx = rules.firstIndex(where: { $0.name == name }) {
                    rules[idx].enabled = enabled
                }
            } catch {
                rulesError = "Failed to toggle \(name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Stats & Check

    func loadStats() {
        Task {
            do {
                statsData = try await cli.stats()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func runCheck() {
        guard !isCheckRunning else { return }
        Task {
            isCheckRunning = true
            error = nil
            checkResult = CheckResult()
            do {
                for try await event in cli.checkStream() {
                    apply(event)
                }
            } catch {
                self.error = error.localizedDescription
            }
            isCheckRunning = false
        }
    }

    private func apply(_ event: CheckEvent) {
        var result = checkResult ?? CheckResult()
        switch event.type {
        case "broken_url":
            if let issue = event.issue {
                var list = result.brokenUrls ?? []
                list.append(issue)
                result.brokenUrls = list
            }
        case "missing_file":
            if let issue = event.issue {
                var list = result.missingFiles ?? []
                list.append(issue)
                result.missingFiles = list
            }
        case "orphaned_file":
            if let path = event.path {
                var list = result.orphanedFiles ?? []
                list.append(path)
                result.orphanedFiles = list
            }
        case "duplicate_group":
            if let group = event.group {
                var list = result.duplicateHashes ?? []
                list.append(group)
                result.duplicateHashes = list
            }
        default:
            // phase_start, progress, done — no accumulation needed.
            break
        }
        checkResult = result
    }

    // MARK: - Saved Searches

    func loadSavedSearches() {
        Task {
            do {
                savedSearches = try await cli.listSavedSearches()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func runSavedSearch(name: String) {
        Task {
            isLoading = true
            error = nil
            do {
                items = try await cli.runSavedSearch(name: name)
                applySortMode()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    func deleteSavedSearch(name: String) {
        Task {
            do {
                try await cli.deleteSavedSearch(name: name)
                loadSavedSearches()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Create or update a Smart Collection from the Mac UI. When
    /// `originalName` differs from `name`, the saved search is
    /// renamed in place first (atomic UPDATE on saved_searches.name)
    /// before the upsert applies the rest of the filter changes.
    /// Calls back on the main actor with `nil` on success or a
    /// human-readable error string.
    func saveSearchFromMac(
        name: String,
        originalName: String? = nil,
        query: String,
        filter: SavedSearch.SearchFilter,
        completion: @escaping (String?) -> Void
    ) {
        Task {
            do {
                if let original = originalName, !original.isEmpty, original != name {
                    try await cli.renameSavedSearch(oldName: original, newName: name)
                }
                try await cli.saveSearch(name: name, query: query, filter: filter)
                loadSavedSearches()
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    // MARK: - Duplicates

    func loadDupes() {
        guard !isDupeRunning else { return }
        Task {
            isDupeRunning = true
            error = nil
            do {
                dupeResults = try await cli.dupes()
            } catch {
                self.error = error.localizedDescription
            }
            isDupeRunning = false
        }
    }

    func markSeen(_ id: String) {
        if seenItemIDs.insert(id).inserted {
            // Keep the set from growing unbounded — trim to last 2000
            if seenItemIDs.count > 2000 {
                seenItemIDs = Set(Array(seenItemIDs).suffix(1500))
            }
            UserDefaults.standard.set(Array(seenItemIDs), forKey: "seenItemIDs")
        }
    }

    func isUnseen(_ id: String) -> Bool {
        !seenItemIDs.contains(id)
    }

    func addTagToItem(id: String, tag: String) {
        Task {
            do {
                _ = try await cli.editItem(id: id, addTags: [tag])
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func addTagsToItem(id: String, tags: [String]) {
        Task {
            do {
                _ = try await cli.editItem(id: id, addTags: tags)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Focus an item by id. Sets BOTH the focus id (drives the
    /// detail pane) and the multi-selection set (drives the list-row
    /// highlight). The List binds to selectedItems, so without the
    /// Set the row never lights up after a programmatic selection.
    ///
    /// `revealInList` controls the navigation switch. Default is
    /// false because Health Check / Dupes / Suggest Rules want to
    /// show the item in the detail pane WITHOUT yanking the user
    /// out of those views. Pass true from QuickSearchView's
    /// commit-result path so a global search hit lands in the list
    /// where the highlight is visible.
    func selectItemByID(_ id: String, revealInList: Bool = false) {
        selectedItemID = id
        selectedItems = [id]

        if revealInList {
            let visibleHere = items.contains(where: { $0.id == id })
            if !visibleHere && navigation != .allItems {
                navigation = .allItems
            }
            pendingRevealID = id
        }

        if items.first(where: { $0.id == id }) == nil {
            Task {
                do {
                    fetchedItem = try await cli.getItem(id: id)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func dismissDupeGroup(_ group: DupeResult) {
        let ids = group.items.map(\.id)
        Task {
            do {
                // Dismiss all pairs in the group
                for i in 0..<ids.count {
                    for j in (i+1)..<ids.count {
                        try await cli.dismissDupePair(idA: ids[i], idB: ids[j])
                    }
                }
                // Remove the group from results
                dupeResults.removeAll { $0.id == group.id }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func deleteItemFromDupes(id: String) {
        // Find the title before deleting for the flash message
        let title = dupeResults.flatMap(\.items).first { $0.id == id }?.title ?? shortID(id)
        Task {
            do {
                try await cli.deleteItem(id: id)
                // Remove the item from dupe results locally
                for i in dupeResults.indices.reversed() {
                    dupeResults[i].items.removeAll { $0.id == id }
                    if dupeResults[i].items.count < 2 {
                        dupeResults.remove(at: i)
                    }
                }
                if selectedItemID == id {
                    selectedItemID = nil
                    fetchedItem = nil
                }
                flashMessage = "Deleted \"\(title)\""
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if flashMessage?.contains(title) == true {
                        flashMessage = nil
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func shortID(_ id: String) -> String {
        String(id.prefix(10))
    }

    // MARK: - Bulk Operations

    func bulkTag(addTags: [String] = [], removeTags: [String] = []) {
        let ids = Array(selectedItems)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await cli.bulkTag(ids: ids, addTags: addTags, removeTags: removeTags)
                selectedItems.removeAll()
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func bulkDelete() {
        let ids = Array(selectedItems)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await cli.bulkDelete(ids: ids)
                selectedItems.removeAll()
                if let sel = selectedItemID, ids.contains(sel) {
                    selectedItemID = nil
                }
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func bulkCollect(collection: String, remove: Bool = false) {
        let ids = Array(selectedItems)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await cli.bulkCollect(ids: ids, collection: collection, remove: remove)
                selectedItems.removeAll()
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func toggleSelection(_ id: String) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    func selectAll() {
        selectedItems = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedItems.removeAll()
    }

    func filterByTag(_ name: String, additive: Bool = false) {
        if additive {
            // Cmd+Click: toggle this tag in the multi-selection
            if filterTags.contains(name) {
                filterTags.remove(name)
            } else {
                filterTags.insert(name)
            }
            filterType = nil
            filterCollection = nil
            searchQuery = ""
            if filterTags.isEmpty && navigation != .tagGraph {
                suppressNavigationChange = true
                navigation = .allItems
                suppressNavigationChange = false
            }
            refresh()
            return
        }

        // Regular click: if already the sole filter, deselect
        if filterTags == [name] {
            filterTags = []
            searchQuery = ""
            if navigation != .tagGraph {
                suppressNavigationChange = true
                navigation = .allItems
                suppressNavigationChange = false
            }
            refresh()
            return
        }

        // Regular click: replace selection with just this tag
        filterType = nil
        filterTags = [name]
        filterCollection = nil
        searchQuery = ""
        if navigation != .tagGraph {
            let tag = tags.first(where: { $0.name == name }) ?? StashTag(id: 0, name: name)
            suppressNavigationChange = true
            navigation = .tag(tag)
            suppressNavigationChange = false
        }
        refresh()
    }

    func handleNavigationChange(_ item: NavigationItem) {
        guard !suppressNavigationChange else { return }
        applyNavigation(item)
    }

    func applyNavigation(_ item: NavigationItem) {
        suppressNavigationChange = true
        defer { suppressNavigationChange = false }
        navigation = item

        switch item {
        case .tagGraph:
            // Keep current filter state — the graph view manages its own filtering
            return
        case .stats:
            loadStats()
            return
        case .check:
            selectedItemID = nil
            return
        case .dupes:
            loadDupes()
            return
        case .savedSearch(let ss):
            runSavedSearch(name: ss.name)
            return
        default:
            filterType = nil
            filterTags = []
            filterCollection = nil
            searchQuery = ""
        }

        switch item {
        case .allItems:
            break
        case .type(let t):
            filterType = t
        case .tag(let t):
            filterTags = [t.name]
        case .collection(let c):
            filterCollection = c.name
        case .tagGraph, .stats, .check, .dupes, .savedSearch, .rules, .ruleActivity, .inbox:
            break
        }
        refresh()
    }

    // MARK: - Inbox

    /// Load all three Inbox sections in parallel (feed candidates,
    /// read/watch queue, resurface picks). Idempotent; safe to call
    /// on view appear and after polls/triage actions.
    ///
    /// Queue slice is intentionally tiny — top 2 newest + bottom 1
    /// oldest = 3 max. Recent commitments stay visible *and* an old
    /// debt rotates back as a nag. The "Show all" header link opens
    /// the full list filtered to both queue tags.
    func loadInbox() {
        Task {
            do {
                async let cands = cli.listFeedCandidates(state: "unread", limit: 200)
                async let queueAll = cli.listReadWatchQueue(limit: 500)
                async let picks = cli.pickResurfaceItems(limit: 8)
                self.feedCandidates = try await cands
                self.queueItems     = pickQueueSlice(try await queueAll)
                self.resurfaceItems = try await picks
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Compose the inbox queue from a full sorted-newest-first list:
    /// 2 newest + 1 oldest, deduped, capped at 3 total. Returns the
    /// full list verbatim when there are <=3 items overall.
    private func pickQueueSlice(_ all: [StashItem]) -> [StashItem] {
        guard all.count > 3 else { return all }
        let newest = Array(all.prefix(2))
        let oldest = all.last!
        // Dedup just in case the oldest happens to be in the newest
        // slice (impossible at count > 3 but cheap insurance).
        if newest.contains(where: { $0.id == oldest.id }) {
            return newest
        }
        return newest + [oldest]
    }

    /// Switch the items list to All Items filtered by the queue tags
    /// (OR semantics — items with either tag are shown). Used by the
    /// Inbox's "Show all" link to take the user from the tiny slice
    /// to the full list.
    ///
    /// Sets the search query rather than `filterTags` directly so the
    /// active filter is visible in the search box — `fetchFilteredItems`
    /// extracts `tag:...` tokens and merges them into the tag filter at
    /// query time. Navigation change runs first; SwiftUI's `.onChange`
    /// fires `applyNavigation(.allItems)` which clears filters, so the
    /// query set is deferred to the next main-actor tick to land
    /// AFTER that reset.
    func showReadWatchList() {
        navigation = .allItems
        Task { @MainActor in
            filterTags = []
            filterType = nil
            filterCollection = nil
            searchQuery = "tag:read-later tag:watch-later"
            refresh()
        }
    }

    /// "Mark done" for a queue item: removes whichever of the queue
    /// tags (`read-later`, `watch-later`) the item currently has, then
    /// reloads the Inbox so the row drops out.
    func markQueueItemDone(_ item: StashItem) {
        let queueTags = ["read-later", "watch-later"]
        let toRemove = (item.tags ?? []).map(\.name).filter { queueTags.contains($0) }
        guard !toRemove.isEmpty else {
            self.loadInbox()
            return
        }
        Task {
            do {
                _ = try await cli.editItem(id: item.id, removeTags: toRemove)
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Fire `stash feeds refresh` and re-load the Inbox. Used by the
    /// auto-poll timer, the manual refresh button, and (optionally)
    /// the menubar quick-action.
    func pollFeeds() {
        Task {
            do {
                try await cli.refreshFeeds()
                self.lastFeedPoll = Date()
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Install / restart the in-app polling timer. Reads
    /// `feedPollIntervalMinutes` from UserDefaults; 0 means disabled
    /// (the user delegated polling to Runbook). Default is 30
    /// minutes when unset.
    func startFeedPollTimer() {
        feedPollTimer?.invalidate()
        feedPollTimer = nil
        let stored = UserDefaults.standard.object(forKey: "feedPollIntervalMinutes") as? Int
        let minutes = stored ?? 30
        guard minutes > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFeeds() }
        }
        RunLoop.main.add(timer, forMode: .common)
        feedPollTimer = timer
        // Fire one immediate poll so a fresh launch fills the inbox
        // without waiting for the first interval to elapse.
        pollFeeds()
    }

    func stopFeedPollTimer() {
        feedPollTimer?.invalidate()
        feedPollTimer = nil
    }

    /// Triage actions used by InboxView; thin wrappers around StashCLI
    /// that refresh the local cache after a successful CLI call.

    func stashCandidate(_ c: FeedCandidate, extraTags: [String] = []) {
        Task {
            do {
                _ = try await cli.stashFeedCandidate(id: c.id, extraTags: extraTags)
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func dismissCandidate(_ c: FeedCandidate) {
        Task {
            do {
                try await cli.dismissFeedCandidate(id: c.id)
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func snoozeCandidate(_ c: FeedCandidate, duration: String) {
        Task {
            do {
                try await cli.snoozeFeedCandidate(id: c.id, duration: duration)
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func dismissResurface(_ item: StashItem) {
        Task {
            do {
                try await cli.dismissResurfaceItem(id: item.id)
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func snoozeResurface(_ item: StashItem, duration: String) {
        Task {
            do {
                try await cli.snoozeResurfaceItem(id: item.id, duration: duration)
                self.loadInbox()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// IDs currently being identified (right-click → Identify with
    /// the active AI provider). The detail pane reads this to show a
    /// small spinner next to the title while the call's in flight.
    var identifyingItemIDs: Set<String> = []

    /// Right-click → Identify with <provider> on an image item.
    /// Reads the image bytes from the local file store, sends them
    /// to the active AI provider with the user's configured prompt
    /// + key, parses the response, then updates the item:
    ///   - Title is filled only when currently blank (don't clobber
    ///     a user-typed value).
    ///   - Notes gets the new prose appended below any existing
    ///     notes, separated by a blank line.
    /// All errors land in `self.error` via the standard alert path.
    func identifyImageItem(id: String, with prefs: AIPrefsStore) {
        guard let item = items.first(where: { $0.id == id })
                ?? fetchedItem.flatMap({ $0.id == id ? $0 : nil })
        else {
            self.error = "Item not found."
            return
        }
        guard item.type == .image else {
            self.error = "Identify only works on image items."
            return
        }
        let provider = prefs.activeProvider
        let key = prefs.apiKey
        guard !key.isEmpty else {
            self.error = "Set a \(provider.displayName) API key in Settings → AI first."
            return
        }
        guard let storePath = item.storePath, !storePath.isEmpty,
              let url = FilePathResolver.resolve(storePath: storePath)
        else {
            self.error = "Couldn't resolve the image file on disk."
            return
        }
        let mime = item.mimeType ?? "image/jpeg"
        let prompt = prefs.promptText
        // Collect the primary blob plus every attached file in
        // carousel order. Multi-photo items (mushroom top/side/
        // bottom, flower-plus-leaves) identify much better when
        // the model sees every angle in one request.
        let attachedURLs: [(URL, String)] = (item.files ?? []).compactMap { f in
            FilePathResolver.resolve(storePath: f.storePath).map { ($0, f.mimeType ?? "image/jpeg") }
        }

        identifyingItemIDs.insert(id)
        flashMessage = "Identifying \(shortID(id)) with \(provider.displayName)…"

        Task { [weak self] in
            defer { Task { @MainActor in self?.identifyingItemIDs.remove(id) } }
            do {
                // `op://` references resolve here, just before the
                // network call — the actual secret never leaves
                // 1Password's keychain.
                let resolvedKey = try await AIKeyResolver.resolve(key)
                var images: [AIImage] = []
                let primaryBytes = try Data(contentsOf: url)
                images.append(AIImage(data: primaryBytes, mimeType: mime))
                for (fileURL, fileMime) in attachedURLs {
                    let data = try Data(contentsOf: fileURL)
                    images.append(AIImage(data: data, mimeType: fileMime))
                }
                // Only downscale when bundling multiple — a single
                // image at native quality gives the model the most
                // detail and has always fit fine in the request
                // budget. Stored blobs are never modified by this.
                let sendImages = images.count > 1
                    ? images.map { downscaleForIdentify($0) }
                    : images
                let result = try await provider.identify(
                    apiKey: resolvedKey,
                    images: sendImages,
                    promptText: prompt
                )
                await self?.applyIdentifyResult(itemID: id, result: result)
            } catch {
                await MainActor.run {
                    self?.flashMessage = nil
                    self?.error = "\(provider.displayName) identify failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func applyIdentifyResult(itemID: String, result: AIIdentifyResult) async {
        guard let item = items.first(where: { $0.id == itemID })
                ?? fetchedItem.flatMap({ $0.id == itemID ? $0 : nil })
        else { return }
        let currentTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = (currentTitle.isEmpty ? result.title : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let existingNotes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combinedNotes: String
        if existingNotes.isEmpty {
            combinedNotes = result.notes
        } else {
            combinedNotes = existingNotes + "\n\n" + result.notes
        }
        do {
            _ = try await cli.editItem(
                id: itemID,
                title: newTitle?.isEmpty == false ? newTitle : nil,
                note: combinedNotes,
                addTags: [],
                removeTags: []
            )
            flashMessage = "Identified ✓"
            refresh()
        } catch {
            flashMessage = nil
            self.error = "Couldn't save identify result: \(error.localizedDescription)"
        }
    }

    // MARK: - Multi-file items

    /// Attach a local file to an item as an additional photo
    /// (carousel slide). Flash-messages the result and refreshes
    /// the store so the detail pane re-renders with the new file.
    func attachFile(to itemID: String, path: String, caption: String? = nil) {
        flashMessage = "Attaching…"
        Task {
            do {
                _ = try await cli.attachFile(itemID: itemID, path: path, caption: caption)
                flashMessage = "File attached ✓"
                refresh()
            } catch {
                flashMessage = nil
                self.error = "Couldn't attach file: \(error.localizedDescription)"
            }
        }
    }

    /// Detach an attached file by its 1-based attachment index
    /// (0 = primary, can't be detached this way).
    func detachFile(from itemID: String, index: Int) {
        Task {
            do {
                _ = try await cli.detachFile(itemID: itemID, index: index)
                flashMessage = "File detached ✓"
                refresh()
            } catch {
                self.error = "Couldn't detach file: \(error.localizedDescription)"
            }
        }
    }

    /// Promote an attached file to be the new primary/cover.
    func promoteFile(in itemID: String, index: Int) {
        Task {
            do {
                _ = try await cli.promoteFile(itemID: itemID, index: index)
                flashMessage = "Primary set ✓"
                refresh()
            } catch {
                self.error = "Couldn't set primary: \(error.localizedDescription)"
            }
        }
    }

    /// Merge a list of source items into the target. Used by the
    /// "Merge into…" context-menu action — typical case: two
    /// captures of the same subject collapsed into one item with
    /// the duplicate's photo as a second slide.
    func mergeItems(targetID: String, sourceIDs: [String]) {
        guard !sourceIDs.isEmpty else { return }
        flashMessage = "Merging \(sourceIDs.count) item(s)…"
        Task {
            do {
                _ = try await cli.mergeItems(targetID: targetID, sourceIDs: sourceIDs)
                flashMessage = "Merged ✓"
                refresh()
            } catch {
                flashMessage = nil
                self.error = "Couldn't merge: \(error.localizedDescription)"
            }
        }
    }
}
