import SwiftUI

struct SidebarView: View {
    @Environment(StashStore.self) private var store
    @Binding var selection: NavigationItem?
    @Binding var showAddCollectionSheet: Bool
    @State private var renamingTag: StashTag?
    @State private var newTagName = ""
    @State private var tagFilter = ""
    @State private var showCloud = false

    private var filteredTags: [StashTag] {
        if tagFilter.isEmpty { return store.tags }
        return store.tags.filter { $0.name.localizedCaseInsensitiveContains(tagFilter) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section("Library") {
                    Label("All Items", systemImage: "tray.full")
                        .tag(NavigationItem.allItems)
                    ForEach(ItemType.allCases) { type in
                        Label(type.label, systemImage: type.icon)
                            .tag(NavigationItem.type(type))
                    }
                    Label("Tag Graph", systemImage: "chart.dots.scatter")
                        .tag(NavigationItem.tagGraph)
                    Label("Stats", systemImage: "chart.bar")
                        .tag(NavigationItem.stats)
                    Label("Duplicates", systemImage: "doc.on.doc")
                        .tag(NavigationItem.dupes)
                    Label("Health Check", systemImage: "checkmark.shield")
                        .tag(NavigationItem.check)
                }

                if !store.savedSearches.isEmpty {
                    Section("Saved Searches") {
                        ForEach(store.savedSearches) { ss in
                            HStack {
                                Label(ss.name, systemImage: "magnifyingglass")
                                Spacer()
                                Text(ss.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .tag(NavigationItem.savedSearch(ss))
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    store.deleteSavedSearch(name: ss.name)
                                }
                            }
                        }
                    }
                }

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
            TextField("Filter", text: $tagFilter)
                .textFieldStyle(.plain)
                .font(.caption)
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
