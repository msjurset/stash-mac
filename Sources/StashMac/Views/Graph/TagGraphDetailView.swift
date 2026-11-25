import SwiftUI
import AppKit

/// Right-hand detail column shown when `store.navigation == .tagGraph`.
/// Clicking a tag node in the graph populates `store.filterTags` and
/// refreshes `store.items`, which this view renders as an interactive
/// stash list with 1st-degree neighbor chips and drill-down into full
/// `ItemDetailView` on item click.
struct TagGraphDetailView: View {
    @Environment(StashStore.self) private var store
    @Binding var showEditSheet: Bool
    @State private var shownThumbnailID: String?

    private var sortedSelectedTags: [String] {
        store.filterTags.sorted()
    }

    /// 1st-degree connected tags for the currently selected tag(s), sorted by co-occurrence weight.
    private var connectedNeighbors: [(name: String, weight: Int)] {
        guard let data = store.tagGraphData, !store.filterTags.isEmpty else { return [] }
        var weights: [String: Int] = [:]
        for edge in data.edges {
            if store.filterTags.contains(edge.tagA) && !store.filterTags.contains(edge.tagB) {
                weights[edge.tagB, default: 0] += edge.weight
            } else if store.filterTags.contains(edge.tagB) && !store.filterTags.contains(edge.tagA) {
                weights[edge.tagA, default: 0] += edge.weight
            }
        }
        return weights
            .map { (name: $0.key, weight: $0.value) }
            .sorted { $0.weight == $1.weight ? $0.name < $1.name : $0.weight > $1.weight }
    }

    var body: some View {
        if store.filterTags.isEmpty {
            ContentUnavailableView(
                "Select a Tag Node",
                systemImage: "chart.dots.scatter",
                description: Text("Click a node to list its stashes here · Double-click to focus its 1st-degree ring · Right-click for tag actions.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.selectedItemID != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        store.selectedItemID = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back to \(tagSummaryTitle) (\(store.items.count))")
                        }
                        .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)

                    Spacer()

                    if let id = store.selectedItemID {
                        Button {
                            store.selectItemByID(id, revealInList: true)
                        } label: {
                            Label("Reveal in List", systemImage: "list.bullet")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()

                DetailRouter(showEditSheet: $showEditSheet)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                if !connectedNeighbors.isEmpty {
                    Divider()
                    neighborsStrip
                }
                Divider()
                stashList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tagSummaryTitle: String {
        sortedSelectedTags.map { "#\($0)" }.joined(separator: " + ")
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tagSummaryTitle)
                        .font(.title3).bold()
                        .lineLimit(1)
                    Text("\(store.items.count) \(store.items.count == 1 ? "stash" : "stashes")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if sortedSelectedTags.count == 1, let sole = sortedSelectedTags.first {
                    Button {
                        let tag = store.tags.first(where: { $0.name == sole }) ?? StashTag(id: 0, name: sole)
                        store.recordNavigationHistory()
                        store.applyNavigation(.tag(tag))
                    } label: {
                        Label("Open in List", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                    .help("Switch to the full list view filtered to #\(sole)")
                }

                Button {
                    store.selectedItemID = nil
                    store.filterTags = []
                    store.refresh()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Clear tag selection")
            }

            if sortedSelectedTags.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sortedSelectedTags, id: \.self) { t in
                            HStack(spacing: 4) {
                                Text("#\(t)")
                                    .font(.caption.bold())
                                Button {
                                    store.filterByTag(t, additive: true)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 1st-Degree Connected Tags Strip

    private var neighborsStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("1st-Degree Connected Tags (\(connectedNeighbors.count))")
                    .font(.caption2).bold()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Click to switch · ⌘-click to combine")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(connectedNeighbors, id: \.name) { neighbor in
                        Button {
                            let additive = NSEvent.modifierFlags.contains(.command)
                            store.selectedItemID = nil
                            store.filterByTag(neighbor.name, additive: additive)
                        } label: {
                            HStack(spacing: 4) {
                                Text("#\(neighbor.name)")
                                    .font(.caption)
                                Text("\(neighbor.weight)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("Click to select #\(neighbor.name) · ⌘-click to filter by both")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Stashes List

    @ViewBuilder
    private var stashList: some View {
        if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty {
            ContentUnavailableView(
                "No Matching Stashes",
                systemImage: "tray",
                description: Text("No stashed items carry all of the selected tags.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.items) { item in
                        stashRow(item)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stashRow(_ item: StashItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            rowLeadingIcon(for: item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? (item.url ?? item.shortID) : item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let sub = rowSubtitle(for: item), !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(.relative(presentation: .numeric)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let tags = item.tags, !tags.isEmpty {
                        ForEach(tags.prefix(4)) { tag in
                            Text("#\(tag.name)")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    store.filterTags.contains(tag.name)
                                        ? Color.orange.opacity(0.20)
                                        : Color.secondary.opacity(0.14),
                                    in: Capsule()
                                )
                                .foregroundStyle(store.filterTags.contains(tag.name) ? .orange : .secondary)
                        }
                        if tags.count > 4 {
                            Text("+\(tags.count - 4)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                store.openItem(id: item.id)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Open stash in default application")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.openItem(id: item.id)
        }
        .onTapGesture(count: 1) {
            store.selectedItemID = item.id
            store.selectedItems = [item.id]
        }
        .contextMenu {
            Button {
                store.selectedItemID = item.id
                store.selectedItems = [item.id]
            } label: {
                Label("Inspect Detail", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                store.openItem(id: item.id)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Button {
                store.selectItemByID(item.id, revealInList: true)
            } label: {
                Label("Reveal in Full List", systemImage: "list.bullet")
            }
            Button {
                store.selectedItemID = item.id
                store.selectedItems = [item.id]
                showEditSheet = true
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            if let url = item.url, !url.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.deleteItem(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func hasThumbnail(for item: StashItem) -> Bool {
        guard let rel = item.thumbnailPath,
              let url = FilePathResolver.resolveRelative(rel),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return true
    }

    @ViewBuilder
    private func rowLeadingIcon(for item: StashItem) -> some View {
        let hasThumb = hasThumbnail(for: item)
        let isPopoverShown = (shownThumbnailID == item.id)

        Image(systemName: item.iconName)
            .font(.body)
            .foregroundStyle(store.isUnseen(item.id) ? .primary : .secondary)
            .frame(width: 22, height: 22)
            .padding(.top, 2)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hasThumb else {
                    NSCursor.pop()
                    return
                }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .highPriorityGesture(
                TapGesture().onEnded {
                    guard hasThumb else { return }
                    if isPopoverShown {
                        shownThumbnailID = nil
                    } else {
                        shownThumbnailID = item.id
                    }
                }
            )
            .popover(
                isPresented: Binding(
                    get: { isPopoverShown },
                    set: { newValue in
                        if !newValue && isPopoverShown {
                            shownThumbnailID = nil
                        }
                    }
                ),
                arrowEdge: .leading
            ) {
                ItemRowPopover(item: item)
                    .onTapGesture {
                        shownThumbnailID = nil
                    }
            }
    }

    private func rowSubtitle(for item: StashItem) -> String? {
        if let url = item.url, !url.isEmpty {
            return url
        }
        if let notes = item.notes, !notes.isEmpty {
            return notes.replacingOccurrences(of: "\n", with: " ")
        }
        if let text = item.extractedText, !text.isEmpty {
            return String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        }
        return nil
    }
}
