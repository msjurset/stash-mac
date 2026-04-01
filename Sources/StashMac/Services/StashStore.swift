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
    var isLoading = false
    var error: String?
    var flashMessage: String?
    var seenItemIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "seenItemIDs") ?? [])
    }()

    private let cli = StashCLI.shared
    private var searchTask: Task<Void, Never>?
    private var suppressNavigationChange = false

    var fetchedItem: StashItem?

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
                items = try await cli.listItems(limit: 100)
                tags = try await cli.listTags()
                collections = try await cli.listCollections()
                tagGraphData = try await cli.tagGraph()
                savedSearches = try await cli.listSavedSearches()
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
                // Parse tag: tokens from the search query and merge with sidebar filter tags
                var allTags = Array(filterTags)
                var textQuery = searchQuery

                if !searchQuery.isEmpty {
                    let pattern = /tag:(\S+)/
                    let inlineMatches = searchQuery.matches(of: pattern)
                    allTags += inlineMatches.map { String($0.output.1) }
                    textQuery = searchQuery.replacing(/tag:\S*/, with: "").trimmingCharacters(in: .whitespaces)
                }

                if textQuery.isEmpty {
                    items = try await cli.listItems(
                        type: filterType,
                        tags: allTags,
                        collection: filterCollection,
                        limit: 100
                    )
                } else {
                    items = try await cli.searchItems(
                        query: textQuery,
                        type: filterType,
                        tags: allTags,
                        limit: 100
                    )
                }
                applySortMode()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
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
            do {
                checkResult = try await cli.check()
            } catch {
                self.error = error.localizedDescription
            }
            isCheckRunning = false
        }
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
        case .tagGraph, .stats, .check, .dupes, .savedSearch:
            break
        }
        refresh()
    }
}
