import SwiftUI
import UniformTypeIdentifiers

/// Identifiable payload for `.sheet(item:)` presentation of
/// `FetchURLSheet`.
struct FetchURLTrigger: Identifiable {
    let id = UUID()
    let initialURL: String?
}

struct ContentView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var showAddItemSheet = false
    @State private var showAddCollectionSheet = false
    @State private var showEditSheet = false
    @State private var showQuickSearch = false
    @State private var showImportBookmarksSheet = false
    @State private var showImportHistorySheet = false
    @State private var fetchURLTrigger: FetchURLTrigger?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var shouldShowAddItemButton: Bool {
        store.navigation != .rules && store.navigation != .ruleActivity
    }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $store.navigation,
                showAddCollectionSheet: $showAddCollectionSheet
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 400, ideal: 600, max: 1000)
        } detail: {
            detailContent
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        actionToolbarItems
                    }
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                navigationToolbarItems
            }
        }
        .sheet(isPresented: $showAddCollectionSheet) {
            AddCollectionSheet()
        }
        .sheet(isPresented: $showAddItemSheet) {
            AddItemSheet()
        }
        .sheet(isPresented: $showEditSheet) {
            if let id = store.selectedItemID,
               let item = store.items.first(where: { $0.id == id }) {
                EditItemSheet(item: item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stashOpenImportBookmarks)) { _ in
            showImportBookmarksSheet = true
        }
        .sheet(isPresented: $showImportBookmarksSheet) {
            ImportBookmarksSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stashOpenImportHistory)) { _ in
            showImportHistorySheet = true
        }
        .sheet(isPresented: $showImportHistorySheet) {
            ImportHistorySheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stashOpenFetchURL)) { note in
            let seedURL = note.userInfo?["url"] as? String
            fetchURLTrigger = FetchURLTrigger(initialURL: seedURL)
        }
        .sheet(item: $fetchURLTrigger) { trigger in
            FetchURLSheet(initialURL: trigger.initialURL)
        }
        .onAppear {
            onAppear()
        }
        .onChange(of: store.navigation) { _, newValue in
            onNavigationChange(newValue)
        }
        .overlay(alignment: .top) {
            ToastOverlay()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: {
            if let error = store.error {
                Text(error)
            }
        }
    }

    private func onNavigationChange(_ newValue: NavigationItem?) {
        let nav = newValue ?? .allItems
        store.handleNavigationChange(nav)
    }

    private func onAppear() {
        store.loadAll()
        store.startFeedPollTimer()
    }

    @ViewBuilder
    private var sidebarContent: some View {
        @Bindable var store = store
        Group {
            switch store.navigation {
            case .tagGraph:
                TagGraphView()
                    .frame(minWidth: 500, idealWidth: 800)
            case .stats:
                StatsView()
            case .check:
                CheckView()
            case .dupes:
                DupesView()
            case .moments:
                MomentsView()
            case .rules:
                RulesView()
            case .ruleActivity:
                RuleActivityView()
            case .inbox:
                InboxView()
            default:
                ItemListView(showEditSheet: $showEditSheet)
            }
        }
    }

    private func helpTopic(for nav: NavigationItem?) -> HelpTopic {
        guard let nav else { return .gettingStarted }
        switch nav {
        case .allItems:                 return .searching
        case .type:                     return .itemTypes
        case .tag, .collection, .archive,
             .savedSearch, .tagGraph:   return .organizing
        case .dupes:                    return .duplicates
        case .stats, .check:            return .statsAndCheck
        case .rules, .ruleActivity:     return .rules
        case .inbox:                    return .gettingStarted
        case .moments:                    return .organizing
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
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
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.navigation {
        case .tagGraph, .stats, .check, .dupes, .rules, .ruleActivity, .moments:
            EmptyView()
        case .inbox:
            InboxDetailView()
        default:
            DetailRouter(showEditSheet: $showEditSheet)
        }
    }

    @ViewBuilder
    private var navigationToolbarItems: some View {
        Button {
            store.goBack()
        } label: {
            Image(systemName: "chevron.left")
        }
        .disabled(!store.canGoBack)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")

        Button {
            store.goForward()
        } label: {
            Image(systemName: "chevron.right")
        }
        .disabled(!store.canGoForward)
        .keyboardShortcut("]", modifiers: .command)
        .help("Forward")
    }

    @ViewBuilder
    private var actionToolbarItems: some View {
        if shouldShowAddItemButton {
            Button {
                showAddItemSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add URL, File, or Snippet (A)")
            .keyboardShortcut("a", modifiers: [])
            .focusable(false)
        }

        Button {
            Task {
                NotificationCenter.default.post(name: .stashOpenFetchURL, object: nil)
            }
        } label: {
            Label("Fetch from URL", systemImage: "link.badge.plus")
        }
        .help("Fetch all images/videos from a URL")
        .focusable(false)

        Button {
            store.loadAll()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh (R)")
        .keyboardShortcut("r", modifiers: .command)
        .focusable(false)
    }

    private func openHelpForCurrentContext() {
        openWindow(id: "help", value: helpTopic(for: store.navigation))
    }
}
