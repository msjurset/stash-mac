import SwiftUI

@Observable
@MainActor
final class StashStore {
    var items: [StashItem] = []
    var tags: [StashTag] = []
    var collections: [StashCollection] = []

    var searchQuery = ""
    var filterType: ItemType?
    var filterTags: Set<String> = []
    var filterCollection: String?
    enum SortMode: String, CaseIterable {
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
            case .newestFirst: return "chevron.down"
            case .oldestFirst: return "chevron.up"
            case .titleAZ: return "textformat.abc"
            case .titleZA: return "textformat.abc"
            }
        }
    }

    var sortMode: SortMode = .newestFirst

    var tagGraphData: TagGraphData?
    var savedSearches: [SavedSearch] = []
    var dupeResults: [DupeResult] = []
    var isDupeRunning = false
    var statsData: StashStatsResponse?
    var checkResult: CheckResult?
    var isCheckRunning = false
    var selectedItems: Set<String> = []
    var navigation: NavigationItem? = .allItems
    var selectedItemID: String? {
        didSet {
            if let id = selectedItemID {
                markSeen(id)
            }
        }
    }
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
        case .newestFirst:
            break // CLI returns newest first by default
        case .oldestFirst:
            items.reverse()
        case .titleAZ:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleZA:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }

    func cycleSortMode() {
        sortMode = sortMode.next
        refresh()
    }

    func addURL(url: String, title: String?, tags: [String], note: String?, collection: String?) {
        Task {
            do {
                _ = try await cli.addURL(url: url, title: title, tags: tags, note: note, collection: collection)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func addFile(path: String, title: String?, tags: [String], note: String?, collection: String?) {
        Task {
            do {
                _ = try await cli.addFile(path: path, title: title, tags: tags, note: note, collection: collection)
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
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

    func editItem(id: String, title: String?, note: String?, extractedText: String? = nil, addTags: [String], removeTags: [String], collection: String?) {
        Task {
            do {
                _ = try await cli.editItem(id: id, title: title, note: note, extractedText: extractedText, addTags: addTags, removeTags: removeTags, collection: collection)
                loadAll()
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
                loadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
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

    func selectItemByID(_ id: String) {
        selectedItemID = id
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
        case .tagGraph, .stats, .check, .dupes, .savedSearch, .rules, .ruleActivity:
            break
        }
        refresh()
    }
}
