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
    @Environment(HelpOverlayModel.self) private var helpModel
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
        ZStack {
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
            // All sheets attached to the main layout
            .sheet(isPresented: $showAddCollectionSheet) { AddCollectionSheet() }
            .sheet(isPresented: $showAddItemSheet) { AddItemSheet() }
            .sheet(isPresented: $showEditSheet) {
                if let id = store.selectedItemID, let item = store.items.first(where: { $0.id == id }) {
                    EditItemSheet(item: item)
                }
            }
            .sheet(isPresented: $showImportBookmarksSheet) { ImportBookmarksSheet() }
            .sheet(isPresented: $showImportHistorySheet) { ImportHistorySheet() }
            .sheet(isPresented: $showQuickSearch) { QuickSearchView() }
            .sheet(item: $fetchURLTrigger) { trigger in FetchURLSheet(initialURL: trigger.initialURL) }
            
            ToastOverlay()
                .frame(maxHeight: .infinity, alignment: .top)
                .zIndex(101)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stashOpenImportBookmarks)) { _ in showImportBookmarksSheet = true }
        .onReceive(NotificationCenter.default.publisher(for: .stashOpenImportHistory)) { _ in showImportHistorySheet = true }
        .onReceive(NotificationCenter.default.publisher(for: .stashOpenFetchURL)) { note in
            let seedURL = note.userInfo?["url"] as? String
            fetchURLTrigger = FetchURLTrigger(initialURL: seedURL)
        }
        .onAppear {
            store.loadAll()
            store.startFeedPollTimer()
        }
        .onChange(of: store.navigation) { _, newValue in
            let nav = newValue ?? .allItems
            store.handleNavigationChange(nav)
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
        .background {
            Button("") { showQuickSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .background {
            Button("") { showQuickSearch = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .background {
            Button("") {
                withAnimation {
                    helpModel.isActive.toggle()
                }
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
            .hidden()
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        @Bindable var store = store
        Group {
            switch store.navigation {
            case .tagGraph:
                TagGraphView().frame(minWidth: 500, idealWidth: 800)
            case .stats: StatsView()
            case .check: CheckView()
            case .dupes: DupesView()
            case .moments: MomentsView()
            case .rules: RulesView()
            case .ruleActivity: RuleActivityView()
            case .inbox: InboxView()
            default: ItemListView(showEditSheet: $showEditSheet)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.navigation {
        case .tagGraph, .stats, .rules, .ruleActivity:
            EmptyView()
        case .inbox:
            InboxDetailView()
        case .moments:
            MomentDetailView()
        case .check, .dupes:
            DetailRouter(showEditSheet: $showEditSheet)
        default:
            DetailRouter(showEditSheet: $showEditSheet)
        }
    }

    @ViewBuilder
    private var navigationToolbarItems: some View {
        Button { store.goBack() } label: { Image(systemName: "chevron.left") }
        .disabled(!store.canGoBack)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")

        Button { store.goForward() } label: { Image(systemName: "chevron.right") }
        .disabled(!store.canGoForward)
        .keyboardShortcut("]", modifiers: .command)
        .help("Forward")
    }

    @ViewBuilder
    private var actionToolbarItems: some View {
        if shouldShowAddItemButton {
            Button { showAddItemSheet = true } label: { Label("Add", systemImage: "plus") }
            .help("Add URL, File, or Snippet (A)")
            .keyboardShortcut("a", modifiers: [])
            .focusable(false)
            .helpAnchor(.addButton)
        }

        Button {
            NotificationCenter.default.post(name: .stashOpenFetchURL, object: nil)
        } label: {
            Label("Fetch from URL", systemImage: "link.badge.plus")
        }
        .help("Fetch all images/videos from a URL")
        .focusable(false)

        Button { store.loadAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        .help("Refresh (R)")
        .keyboardShortcut("r", modifiers: .command)
        .focusable(false)
    }
}
