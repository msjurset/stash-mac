import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.openWindow) private var openWindow
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
                    .frame(minWidth: 500, idealWidth: 600)
            case .stats:
                StatsView()
            case .check:
                CheckView()
            case .dupes:
                DupesView()
            case .rules:
                RulesView()
            case .ruleActivity:
                RuleActivityView()
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
            case .stats:
                EmptyView()
            case .rules:
                RuleDetailView()
            case .ruleActivity:
                RuleActivityDetailView()
            case .check:
                DetailRouter(showEditSheet: $showEditSheet)
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
        .onDrop(of: [.fileURL, .emailMessage], isTargeted: nil) { providers in
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
            // Hide on Rules — that view owns its own "+ New Rule" button.
            // Also hide on Rule Activity — that's a read-only feed; "Add
            // item" doesn't make sense there. ⌘N shortcut suppressed too.
            if store.navigation != .rules && store.navigation != .ruleActivity {
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
        }
        .background(SearchKeyMonitor(
            onSearch: { showQuickSearch = true },
            onHelp: { openHelpForCurrentContext() }
        ))
        .keyboardShortcut("k", modifiers: .command) {
            showQuickSearch = true
        }
        .frame(minWidth: 900, minHeight: 500)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            ),
            presenting: store.error
        ) { _ in
            Button("OK", role: .cancel) { store.error = nil }
        } message: { message in
            Text(message)
        }
    }

    /// Open the help window pre-selected to the topic that best
    /// matches the current sidebar navigation. Falls back to
    /// "Getting Started" when nothing maps cleanly.
    private func openHelpForCurrentContext() {
        let topic = helpTopic(for: store.navigation)
        openWindow(id: "help", value: topic)
    }

    private func helpTopic(for nav: NavigationItem?) -> HelpTopic {
        guard let nav else { return .gettingStarted }
        switch nav {
        case .allItems:                 return .searching
        case .type:                     return .itemTypes
        case .tag, .collection,
             .savedSearch, .tagGraph:   return .organizing
        case .dupes:                    return .duplicates
        case .stats, .check:            return .statsAndCheck
        case .rules, .ruleActivity:     return .rules
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            // Try file URL first
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let u = item as? URL {
                        url = u
                    } else if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        store.addFile(path: url.path, title: nil, tags: [], note: nil, collection: nil)
                    }
                }
            }
            // Try email message (e.g., dragged from Apple Mail)
            else if provider.hasItemConformingToTypeIdentifier(UTType.emailMessage.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.emailMessage.identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    let tempPath = NSTemporaryDirectory() + "stash-drop-\(UUID().uuidString).eml"
                    let tempURL = URL(fileURLWithPath: tempPath)
                    do {
                        try data.write(to: tempURL)
                        Task { @MainActor in
                            store.addFile(path: tempPath, title: nil, tags: [], note: nil, collection: nil)
                            try? FileManager.default.removeItem(at: tempURL)
                        }
                    } catch {}
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

/// Monitors for "/" / Cmd+F (search) and "?" (help) when no text
/// field has focus, dispatching to the matching action. Mid-text
/// keystrokes pass through unchanged so the user can type literal
/// slashes / question-marks inside fields.
struct SearchKeyMonitor: NSViewRepresentable {
    let onSearch: () -> Void
    let onHelp: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyMonitorView()
        view.onSearch = onSearch
        view.onHelp = onHelp
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyMonitorView else { return }
        view.onSearch = onSearch
        view.onHelp = onHelp
    }

    class KeyMonitorView: NSView {
        var onSearch: (() -> Void)?
        var onHelp: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                let chars = event.charactersIgnoringModifiers
                let withModifiers = event.characters
                let plainKey = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == []
                let onlyShift = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift

                // "?" (Shift-/) opens contextual help. Always literal
                // when a text field has focus — even an empty one,
                // since `?` isn't a recognized search prefix and the
                // user may genuinely want to type it. Different rule
                // from "/" which has the empty-field carveout.
                if (withModifiers == "?" || (chars == "/" && onlyShift)) && !Self.isTextFieldActive(for: event) {
                    if let onHelp = self.onHelp {
                        DispatchQueue.main.async { onHelp() }
                        return nil
                    }
                }

                // "/" without modifiers (and not in a non-empty text
                // field). Check the event's own window so typing in
                // sheets/popovers doesn't get hijacked when the main
                // window has no focused field. We allow `/` to fire
                // global search even when a text field has focus IF
                // that field is empty — this catches the common
                // first-load case where the list filter field has
                // initial focus and the user types `/` expecting to
                // open global search. Mid-text `/` keeps its literal
                // meaning so users can include slashes in queries.
                if chars == "/" && plainKey {
                    if !Self.isTextFieldActive(for: event) || Self.isFocusedFieldEmpty(for: event) {
                        if let onSearch = self.onSearch {
                            DispatchQueue.main.async { onSearch() }
                            return nil
                        }
                    }
                }

                // Cmd+F
                if chars == "f" && event.modifierFlags.contains(.command) {
                    if let onSearch = self.onSearch {
                        DispatchQueue.main.async { onSearch() }
                        return nil
                    }
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

        private static func isTextFieldActive(for event: NSEvent) -> Bool {
            let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
            return responder is NSTextView || responder is NSTextField
        }

        /// True when the focused text field (if any) currently has no
        /// text. Used to let `/` open global search when the list
        /// filter field has initial focus on app launch — the user
        /// hasn't started typing a query, so `/` should mean "open
        /// global search" rather than "literal slash."
        private static func isFocusedFieldEmpty(for event: NSEvent) -> Bool {
            let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
            if let tv = responder as? NSTextView {
                return tv.string.isEmpty
            }
            if let tf = responder as? NSTextField {
                return tf.stringValue.isEmpty
            }
            // Field editor case — NSTextView whose delegate is the
            // owning NSTextField. Check the field's value.
            if let editor = responder as? NSText,
               let field = editor.delegate as? NSTextField {
                return field.stringValue.isEmpty
            }
            return false
        }
    }
}
