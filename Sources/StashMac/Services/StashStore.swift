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

    var selectedItemID: String?
    var isLoading = false
    var error: String?

    private let cli = StashCLI.shared

    var selectedItem: StashItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    func loadAll() {
        Task {
            isLoading = true
            error = nil
            do {
                async let fetchedItems = cli.listItems(limit: 200)
                async let fetchedTags = cli.listTags()
                async let fetchedCollections = cli.listCollections()
                items = try await fetchedItems
                tags = try await fetchedTags
                collections = try await fetchedCollections
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
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
                        limit: 200
                    )
                } else {
                    items = try await cli.searchItems(
                        query: searchQuery,
                        type: filterType,
                        tag: filterTag,
                        limit: 200
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

    func applyNavigation(_ item: NavigationItem) {
        filterType = nil
        filterTag = nil
        filterCollection = nil

        switch item {
        case .allItems:
            break
        case .type(let t):
            filterType = t
        case .tag(let t):
            filterTag = t.name
        case .collection(let c):
            filterCollection = c.name
        }
        refresh()
    }
}
