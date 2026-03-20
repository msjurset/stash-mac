import SwiftUI

@Observable
@MainActor
final class StashStore {
    var items: [StashItem] = []
    var tags: [StashTag] = []
    var collections: [StashCollection] = []

    var searchQuery = ""
    var filterType: ItemType?
    var filterTag: String?
    var filterCollection: String?

    var tagGraphData: TagGraphData?
    var navigation: NavigationItem? = .allItems
    var selectedItemID: String?
    var isLoading = false
    var error: String?

    private let cli = StashCLI.shared
    private var searchTask: Task<Void, Never>?
    private var suppressNavigationChange = false

    var selectedItem: StashItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    func loadAll() {
        Task {
            isLoading = true
            error = nil
            do {
                items = try await cli.listItems(limit: 100)
                tags = try await cli.listTags()
                collections = try await cli.listCollections()
                tagGraphData = try await cli.tagGraph()
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
        Task {
            isLoading = true
            error = nil
            do {
                if searchQuery.isEmpty {
                    items = try await cli.listItems(
                        type: filterType,
                        tag: filterTag,
                        collection: filterCollection,
                        limit: 100
                    )
                } else {
                    items = try await cli.searchItems(
                        query: searchQuery,
                        type: filterType,
                        tag: filterTag,
                        limit: 100
                    )
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
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
                try await cli.deleteItem(id: id)
                if selectedItemID == id {
                    selectedItemID = nil
                }
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

    func filterByTag(_ name: String) {
        // Toggle: if already filtering by this tag, clear the filter
        if filterTag == name {
            if navigation == .tagGraph {
                // Stay on graph, just clear the filter
                filterTag = nil
                searchQuery = ""
                refresh()
            } else {
                applyNavigation(.allItems)
            }
            return
        }

        if navigation == .tagGraph {
            // Stay on graph view, just update the filter and refresh the list
            filterType = nil
            filterTag = name
            filterCollection = nil
            searchQuery = ""
            refresh()
        } else {
            let tag = tags.first(where: { $0.name == name }) ?? StashTag(id: 0, name: name)
            applyNavigation(.tag(tag))
        }
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
        default:
            filterType = nil
            filterTag = nil
            filterCollection = nil
            searchQuery = ""
        }

        switch item {
        case .allItems:
            break
        case .type(let t):
            filterType = t
        case .tag(let t):
            filterTag = t.name
        case .collection(let c):
            filterCollection = c.name
        case .tagGraph:
            break
        }
        refresh()
    }
}
