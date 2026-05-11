import SwiftUI

struct SidebarView: View {
    @Environment(StashStore.self) private var store
    @Binding var selection: NavigationItem?
    @Binding var showAddCollectionSheet: Bool
    @State private var renamingTag: StashTag?
    @State private var newTagName = ""
    @State private var tagFilter = ""
    @State private var showCloud = false
    /// Drives the smart-collection sheet. `.create` opens an empty
    /// sheet; `.edit(savedSearch)` pre-populates from the existing
    /// row. `.sheet(item:)` keys off the case so toggling between
    /// the two re-presents instead of stale-rendering.
    @State private var smartCollectionSheet: SmartCollectionSheetMode?
    /// Drives the unified create sheet for the merged Collections
    /// section. Bool is enough — the sheet itself owns the
    /// static-vs-smart toggle.
    @State private var showCollectionCreateSheet = false
    /// Per-row hover state for collection drop targets — flips to
    /// true when a drag enters the row's bounds, used to highlight
    /// the active drop target.
    @State private var hoveredCollectionID: Int64?
    /// Tag-row equivalent of `hoveredCollectionID`. Tracks which tag
    /// row is the active drop target so we can highlight it during
    /// drag.
    @State private var hoveredTagName: String?

    enum SmartCollectionSheetMode: Identifiable, Hashable {
        case create
        case edit(SavedSearch)
        var id: String {
            switch self {
            case .create: return "__create__"
            case .edit(let ss): return "edit-\(ss.id)"
            }
        }
    }

    private var filteredTags: [StashTag] {
        if tagFilter.isEmpty { return store.tags }
        return store.tags.filter { $0.name.localizedCaseInsensitiveContains(tagFilter) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                // Library — just All Items now. Per-type filtering moved
                // into a chip bar at the top of ItemListView so the
                // sidebar isn't 12 rows of clutter.
                Section("Library") {
                    Label("All Items", systemImage: "tray.full")
                        .tag(NavigationItem.allItems)
                }
                .opacity(ineligibleSectionOpacity)

                // Tools — analytical / maintenance views. They don't
                // produce or modify items themselves; they're "stuff
                // about your stuff".
                Section("Tools") {
                    Label("Tag Graph", systemImage: "chart.dots.scatter")
                        .tag(NavigationItem.tagGraph)
                    Label("Stats", systemImage: "chart.bar")
                        .tag(NavigationItem.stats)
                    Label("Duplicates", systemImage: "doc.on.doc")
                        .tag(NavigationItem.dupes)
                    Label("Health Check", systemImage: "checkmark.shield")
                        .tag(NavigationItem.check)
                }
                .opacity(ineligibleSectionOpacity)

                // Rules — automation. Activity is intentionally left as
                // a sibling rather than nested under Rules so a quick
                // glance at recent fires doesn't require selecting a
                // specific rule first.
                Section("Rules") {
                    Label("Rules", systemImage: "wand.and.stars")
                        .tag(NavigationItem.rules)
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                        .tag(NavigationItem.ruleActivity)
                }
                .opacity(ineligibleSectionOpacity)

                // Collections (static + smart, merged). Lives just
                // above the Tags section per user preference.
                collectionsSection

                Section {
                    if showCloud {
                        tagCloudView
                    } else {
                        tagListView
                    }
                } header: {
                    tagSectionHeader
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Stash")
            .onChange(of: store.filterTags) { _, newTags in
                if let tagName = newTags.first {
                    withAnimation {
                        proxy.scrollTo(tagName, anchor: .center)
                    }
                }
            }
        }
        .sheet(isPresented: .init(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )) {
            // Sheet (not alert) so we can use FilterField — SwiftUI's
            // TextField inside `.alert(...)` on macOS triggers the
            // phantom autofill / inline-prediction popup that no
            // modifier can suppress. Banned per CLAUDE.md.
            RenameTagSheet(
                originalName: renamingTag?.name ?? "",
                newName: $newTagName,
                onCommit: {
                    if let tag = renamingTag, !newTagName.isEmpty {
                        store.renameTag(old: tag.name, new: newTagName)
                    }
                    renamingTag = nil
                },
                onCancel: { renamingTag = nil }
            )
        }
        .sheet(item: $smartCollectionSheet) { mode in
            switch mode {
            case .create:
                SmartCollectionSheet(editing: nil)
            case .edit(let ss):
                SmartCollectionSheet(editing: ss)
            }
        }
        .sheet(isPresented: $showCollectionCreateSheet) {
            CollectionCreateSheet()
        }
    }

    // MARK: - Collections (static + smart, merged)

    /// Combined Collections section. Static (`folder` icon) and smart
    /// (`sparkles.rectangle.stack` icon) live side-by-side; static
    /// rows accept item drops, smart rows don't (they're saved
    /// queries — adding an item wouldn't even make sense). Single
    /// `+` button in the header opens the unified create sheet
    /// where the user picks Static vs Smart via a segmented control.
    /// Static collections and saved searches both store an `Int64`
    /// `id` from their respective DB tables, so collection.id=3 and
    /// savedSearch.id=3 collide when fed into a single Section via
    /// two sibling `ForEach`. SwiftUI's diffing dedupes one of them,
    /// rendering whichever ForEach ran first as a duplicate row.
    /// Namespacing the ids per-source breaks the collision.
    private enum CollectionEntry: Identifiable, Hashable {
        case staticCollection(StashCollection)
        case smartCollection(SavedSearch)

        var id: String {
            switch self {
            case .staticCollection(let c): return "static-\(c.id)"
            case .smartCollection(let s): return "smart-\(s.id)"
            }
        }
    }

    private var combinedCollectionEntries: [CollectionEntry] {
        store.collections.map { .staticCollection($0) }
            + store.savedSearches.map { .smartCollection($0) }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        Section {
            ForEach(combinedCollectionEntries) { entry in
                switch entry {
                case .staticCollection(let col):
                    Label(col.name, systemImage: "folder")
                        .tag(NavigationItem.collection(col))
                        .listRowBackground(
                            hoveredCollectionID == col.id
                                ? Color.accentColor.opacity(0.25)
                                : nil
                        )
                        .dropDestination(for: String.self) { payloads, _ in
                            let ids = payloads
                                .flatMap { $0.split(separator: ",").map(String.init) }
                                .filter { !$0.isEmpty }
                            guard !ids.isEmpty else { return false }
                            store.bulkAddToCollection(ids: ids, collection: col.name)
                            return true
                        } isTargeted: { isOver in
                            if isOver {
                                hoveredCollectionID = col.id
                            } else if hoveredCollectionID == col.id {
                                hoveredCollectionID = nil
                            }
                        }
                        .contextMenu {
                            Button("Export Collection…") {
                                exportCollection(col.name)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.deleteCollection(name: col.name)
                            }
                        }
                case .smartCollection(let ss):
                    Label(ss.name, systemImage: "sparkles.rectangle.stack")
                        .tag(NavigationItem.savedSearch(ss))
                        .opacity(ineligibleSectionOpacity)
                        .help(ss.summary.isEmpty ? "Smart Collection" : ss.summary)
                        .contextMenu {
                            Button("Edit…") {
                                smartCollectionSheet = .edit(ss)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.deleteSavedSearch(name: ss.name)
                            }
                        }
                }
            }
            if combinedCollectionEntries.isEmpty {
                Button {
                    showCollectionCreateSheet = true
                } label: {
                    Label("New Collection…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Collections")
                Spacer()
                Button {
                    showCollectionCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New Collection")
            }
        }
    }

    /// Opacity for sections that don't accept item drops. Drops to
    /// 0.4 during a drag, full opacity otherwise. Cheap visual cue
    /// that says "these aren't drop targets."
    private var ineligibleSectionOpacity: Double {
        store.isDraggingItems ? 0.35 : 1.0
    }

    // MARK: - Saved-search / smart-collection row

    @ViewBuilder
    private func savedSearchRow(_ ss: SavedSearch, icon: String) -> some View {
        // Stack name above the parameter summary so neither has to
        // truncate to fit on a single line. Parameter summary is
        // hidden when empty (it would just be blank padding).
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ss.name)
                    .lineLimit(1)
                if !ss.summary.isEmpty {
                    Text(ss.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .tag(NavigationItem.savedSearch(ss))
        .contextMenu {
            Button("Edit…") {
                smartCollectionSheet = .edit(ss)
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteSavedSearch(name: ss.name)
            }
        }
    }

    // MARK: - Tag Section Header

    private var tagSectionHeader: some View {
        HStack(spacing: 4) {
            Text("Tags")
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCloud.toggle()
                }
            } label: {
                Image(systemName: showCloud ? "list.bullet" : "cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showCloud ? "Show as list" : "Show as cloud")
        }
    }

    // MARK: - Tag List View

    @ViewBuilder
    private var tagListView: some View {
        tagFilterField
        ForEach(filteredTags) { tag in
            let selected = isSelectedTag(tag.name)
            let graphActive = isActiveGraphTag(tag.name)
            Button {
                store.filterByTag(tag.name, additive: NSEvent.modifierFlags.contains(.command))
            } label: {
                HStack {
                    Label(tag.name, systemImage: "tag")
                        .fontWeight(graphActive ? .bold : selected ? .medium : .regular)
                        .foregroundStyle(graphActive ? .orange : selected ? .white : .primary)
                    Spacer()
                    Text("\(tag.count ?? 0)")
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary)
                }
                // Whole-row hit target so left-click and right-click
                // register from the empty space between label and
                // count, not just on the text glyphs.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                hoveredTagName == tag.name
                    ? Color.accentColor.opacity(0.5)
                    : (selected ? Color.accentColor : nil)
            )
            .id(tag.name)
            // Drop destination: drag items from the main list onto a
            // tag row to apply that tag. Payload is the comma-joined
            // id list emitted by ItemListView's drag closure (single
            // id when the dragged row isn't multi-selected, all
            // selected ids when it is). Hover highlight via
            // `isTargeted` shows the active drop target during drag.
            .dropDestination(for: String.self) { payloads, _ in
                let ids = payloads
                    .flatMap { $0.split(separator: ",").map(String.init) }
                    .filter { !$0.isEmpty }
                guard !ids.isEmpty else { return false }
                store.bulkAddTag(ids: ids, tag: tag.name)
                return true
            } isTargeted: { isOver in
                if isOver {
                    hoveredTagName = tag.name
                } else if hoveredTagName == tag.name {
                    hoveredTagName = nil
                }
            }
            .contextMenu {
                Button("Rename...") {
                    renamingTag = tag
                    newTagName = tag.name
                }
                Divider()
                Button("Export Tag…") {
                    exportTag(tag.name)
                }
            }
        }
        if filteredTags.isEmpty && !store.tags.isEmpty {
            Text("No matching tags")
                .foregroundStyle(.secondary)
        }
        if store.tags.isEmpty {
            Text("No tags yet")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tag Cloud View

    @ViewBuilder
    private var tagCloudView: some View {
        tagFilterField
        let tags = filteredTags
        if tags.isEmpty {
            Text(store.tags.isEmpty ? "No tags yet" : "No matching tags")
                .foregroundStyle(.secondary)
        } else {
            let maxCount = tags.map { $0.count ?? 0 }.max() ?? 1
            FlowLayout(spacing: 4) {
                ForEach(tags) { tag in
                    let count = tag.count ?? 0
                    let weight = maxCount > 0 ? Double(count) / Double(maxCount) : 0
                    Text(tag.name)
                        .font(.system(size: fontSize(for: weight)))
                        .fontWeight(fontWeight(for: weight))
                        .foregroundStyle(tagColor(for: weight, active: isSelectedTag(tag.name)))
                        .onTapGesture {
                            store.filterByTag(tag.name, additive: NSEvent.modifierFlags.contains(.command))
                        }
                        .contextMenu {
                            Button("Rename...") {
                                renamingTag = tag
                                newTagName = tag.name
                            }
                            Divider()
                            Button("Export Tag…") {
                                exportTag(tag.name)
                            }
                        }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Filter Field

    private var tagFilterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            FilterField(
                placeholder: "Filter",
                text: $tagFilter,
                font: .preferredFont(forTextStyle: .caption1)
            )
            if !tagFilter.isEmpty {
                Button {
                    tagFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Helpers

    private func isActiveGraphTag(_ name: String) -> Bool {
        store.navigation == .tagGraph && store.filterTags.contains(name)
    }

    private func fontSize(for weight: Double) -> CGFloat {
        // Range: 10pt (least used) to 18pt (most used)
        10 + weight * 8
    }

    private func fontWeight(for weight: Double) -> Font.Weight {
        switch weight {
        case 0.6...: return .bold
        case 0.3...: return .medium
        default: return .regular
        }
    }

    private func isSelectedTag(_ name: String) -> Bool {
        store.filterTags.contains(name)
    }

    private func tagColor(for weight: Double, active: Bool) -> Color {
        if active { return .accentColor }
        switch weight {
        case 0.6...: return .primary
        case 0.3...: return .primary.opacity(0.8)
        default: return .secondary
        }
    }

    /// Surface a Save panel and run `stash export --tag <name>`.
    private func exportTag(_ name: String) {
        let suggested = ExportPanels.suggestedFilename(forScopeLabel: "tag-\(name)")
        guard let outPath = ExportPanels.chooseExportDestination(suggestedName: suggested) else { return }
        store.exportItems(scope: .tag(name), to: outPath)
    }

    /// Surface a Save panel and run `stash export --collection <name>`.
    private func exportCollection(_ name: String) {
        let suggested = ExportPanels.suggestedFilename(forScopeLabel: "collection-\(name)")
        guard let outPath = ExportPanels.chooseExportDestination(suggestedName: suggested) else { return }
        store.exportItems(scope: .collection(name), to: outPath)
    }
}

/// Replacement for the deprecated `.alert("Rename Tag")` flow. Lives
/// in a sheet so the input can use `FilterField` — the only macOS
/// text-input that has the full five-layer autofill suppression
/// stack the project requires.
private struct RenameTagSheet: View {
    let originalName: String
    @Binding var newName: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tag")
                .font(.headline)
            Text("Renaming **\(originalName)** — applies to every item tagged with it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FilterField(
                placeholder: "New name",
                text: $newName,
                autoFocus: true,
                onSubmit: onCommit
            )
            .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
