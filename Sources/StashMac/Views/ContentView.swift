import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(StashStore.self) private var store
    @State private var showAddSheet = false
    @State private var showAddCollectionSheet = false
    @State private var showEditSheet = false
    @State private var showQuickSearch = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $store.navigation,
                showAddCollectionSheet: $showAddCollectionSheet
            )
        } content: {
            switch store.navigation {
            case .tagGraph:
                TagGraphView()
            case .stats:
                StatsView()
            case .check:
                CheckView()
            case .dupes:
                DupesView()
            default:
                ItemListView(showEditSheet: $showEditSheet)
            }
        } detail: {
            switch store.navigation {
            case .tagGraph:
                VSplitView {
                    ItemListView(showEditSheet: $showEditSheet)
                        .frame(maxWidth: .infinity, minHeight: 150)
                    DetailRouter(showEditSheet: $showEditSheet)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                .frame(maxWidth: .infinity)
            case .stats, .check:
                EmptyView()
            case .dupes:
                DetailRouter(showEditSheet: $showEditSheet)
            case .savedSearch:
                DetailRouter(showEditSheet: $showEditSheet)
            default:
                DetailRouter(showEditSheet: $showEditSheet)
            }
        }
        .onAppear {
            store.loadAll()
        }
        .onChange(of: store.navigation) { _, newValue in
            store.handleNavigationChange(newValue ?? .allItems)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(isPresented: $showAddSheet) {
            AddItemSheet()
        }
        .sheet(isPresented: $showAddCollectionSheet) {
            AddCollectionSheet()
        }
        .sheet(isPresented: $showEditSheet) {
            if let item = store.selectedItem {
                EditItemSheet(item: item)
            }
        }
        .sheet(isPresented: $showQuickSearch) {
            QuickSearchView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("Add new item (⌘N)")
            }
        }
        .background(SearchKeyMonitor {
            showQuickSearch = true
        })
        .keyboardShortcut("k", modifiers: .command) {
            showQuickSearch = true
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    store.addFile(path: url.path, title: nil, tags: [], note: nil, collection: nil)
                }
            }
        }
    }
}

private extension View {
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        background(
            Button("") { action() }
                .keyboardShortcut(key, modifiers: modifiers)
                .hidden()
        )
    }
}

/// Monitors for "/" and Cmd+F key presses when no text field is active,
/// and triggers the search action.
struct SearchKeyMonitor: NSViewRepresentable {
    let onSearch: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyMonitorView()
        view.onSearch = onSearch
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class KeyMonitorView: NSView {
        var onSearch: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let onSearch = self.onSearch else { return event }

                // "/" without modifiers (and not in a text field)
                if event.charactersIgnoringModifiers == "/" && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] {
                    if !self.isTextFieldActive {
                        DispatchQueue.main.async { onSearch() }
                        return nil // consume the event
                    }
                }

                // Cmd+F
                if event.charactersIgnoringModifiers == "f" && event.modifierFlags.contains(.command) {
                    DispatchQueue.main.async { onSearch() }
                    return nil
                }

                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            super.removeFromSuperview()
        }

        private var isTextFieldActive: Bool {
            guard let responder = window?.firstResponder else { return false }
            return responder is NSTextView || responder is NSTextField
        }
    }
}
