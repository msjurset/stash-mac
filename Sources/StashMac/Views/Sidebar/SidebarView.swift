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

                savedSearchSections

                Section {
                    if showCloud {
                        tagCloudView
                    } else {
                        tagListView
                    }
                } header: {
                    tagSectionHeader
                }

                Section("Collections") {
                    ForEach(store.collections) { col in
                        Label(col.name, systemImage: "folder")
                            .tag(NavigationItem.collection(col))
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    store.deleteCollection(name: col.name)
                                }
                            }
                    }
                    Button {
                        showAddCollectionSheet = true
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
        .alert("Rename Tag", isPresented: .init(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )) {
            TextField("New name", text: $newTagName)
            Button("Rename") {
                if let tag = renamingTag, !newTagName.isEmpty {
                    store.renameTag(old: tag.name, new: newTagName)
                }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) {
                renamingTag = nil
            }
        }
        .sheet(item: $smartCollectionSheet) { mode in
            switch mode {
            case .create:
                SmartCollectionSheet(editing: nil)
            case .edit(let ss):
                SmartCollectionSheet(editing: ss)
            }
        }
    }

    // MARK: - Saved-search / smart-collection sections

    /// Smart Collections section, extracted out of the main `body` so
    /// ViewBuilder's 10-children limit on the outer `List` doesn't trip
    /// over the always-shown section.
    ///
    /// Plus-button placement is conditional: when the section is empty
    /// the "+ New Smart Collection…" full-width button lives inside the
    /// section as the discoverable empty-state. Once at least one row
    /// exists we tuck a small "+" into the section header's trailing
    /// edge so each row keeps the full width for its name + params.
    @ViewBuilder
    private var savedSearchSections: some View {
        Section {
            ForEach(store.savedSearches) { ss in
                savedSearchRow(ss, icon: "sparkles.rectangle.stack")
            }
            if store.savedSearches.isEmpty {
                Button {
                    smartCollectionSheet = .create
                } label: {
                    Label("New Smart Collection…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Smart Collections")
                Spacer()
                if !store.savedSearches.isEmpty {
                    Button {
                        smartCollectionSheet = .create
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Smart Collection")
                }
            }
        }
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
            }
            .buttonStyle(.plain)
            .listRowBackground(selected ? Color.accentColor : nil)
            .id(tag.name)
            .contextMenu {
                Button("Rename...") {
                    renamingTag = tag
                    newTagName = tag.name
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
}
