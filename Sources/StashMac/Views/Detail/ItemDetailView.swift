import SwiftUI

struct ItemDetailView: View {
    @Environment(StashStore.self) private var store
    let item: StashItem
    @Binding var showEditSheet: Bool
    @State private var showDeleteConfirm = false
    @State private var showLinkSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: item.type.icon)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(item.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                        Text(item.type.label.dropLast() + " \u{2022} " + item.shortID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                // Image preview
                if item.type == .image, let storePath = item.storePath,
                   let fileURL = FilePathResolver.resolve(storePath: storePath),
                   let nsImage = NSImage(contentsOf: fileURL) {
                    DetailSection(title: "Preview") {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 500, maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // URL
                if let urlString = item.url, !urlString.isEmpty {
                    DetailSection(title: "URL") {
                        if let url = URL(string: urlString) {
                            Link(urlString, destination: url)
                                .font(.body)
                        } else {
                            Text(urlString)
                                .foregroundStyle(.blue)
                                .textSelection(.enabled)
                        }
                    }
                }

                // Notes
                if let notes = item.notes, !notes.isEmpty {
                    DetailSection(title: "Notes") {
                        Text(notes)
                            .textSelection(.enabled)
                    }
                }

                // Tags
                if let tags = item.tags, !tags.isEmpty {
                    DetailSection(title: "Tags") {
                        FlowLayout(spacing: 6) {
                            ForEach(tags) { tag in
                                Button {
                                    store.filterByTag(tag.name)
                                } label: {
                                    Text("#\(tag.name)")
                                        .kerning(0.5)
                                        .font(.callout)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            }
                        }
                    }
                }

                // Collections
                if let cols = item.collections, !cols.isEmpty {
                    DetailSection(title: "Collections") {
                        HStack {
                            ForEach(cols) { col in
                                Label(col.name, systemImage: "folder")
                                    .font(.callout)
                            }
                        }
                    }
                }

                // Linked Items
                if let links = item.links, !links.isEmpty {
                    DetailSection(title: "Linked Items") {
                        ForEach(links) { link in
                            HStack {
                                Text(link.directionArrow)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                Image(systemName: link.type.icon)
                                    .foregroundStyle(.secondary)
                                Button {
                                    store.selectedItemID = link.itemId
                                } label: {
                                    Text(link.title)
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                if let label = link.label, !label.isEmpty {
                                    Text("(\(label))")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button {
                                    store.unlinkItems(idA: item.id, idB: link.itemId)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // File info
                if item.mimeType != nil || item.fileSize != nil {
                    DetailSection(title: "File Info") {
                        if let mime = item.mimeType {
                            LabeledContent("MIME Type", value: mime)
                        }
                        if let size = item.humanFileSize {
                            LabeledContent("Size", value: size)
                        }
                        if let source = item.sourcePath {
                            LabeledContent("Source") {
                                Text(source)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                // Archive contents
                if let mime = item.mimeType, isArchiveMIME(mime),
                   let storePath = item.storePath,
                   let fileURL = FilePathResolver.resolve(storePath: storePath) {
                    ArchiveContentsView(fileURL: fileURL, mimeType: mime)
                }

                // Extracted text (skip for archives — tree view is shown instead)
                if let text = item.extractedText, !text.isEmpty,
                   !(item.mimeType.map(isArchiveMIME) ?? false) {
                    ExtractedTextView(text: text)
                }

                // Dates
                DetailSection(title: "Dates") {
                    LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup {
                ContextualHelpButton(topic: .itemDetail)
                Button { showLinkSheet = true } label: {
                    Label("Link...", systemImage: "link")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Link to another item")
                Button { store.openItem(id: item.id) } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .help("Open in default application")
                Button { showEditSheet = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit item")
                Button { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete item")
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            LinkItemSheet(sourceItemID: item.id)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let droppedID = items.first, droppedID != item.id else { return false }
            store.linkItems(from: item.id, to: droppedID)
            return true
        }
        .confirmationDialog("Delete \"\(item.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                store.deleteItem(id: item.id)
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

func isArchiveMIME(_ mimeType: String) -> Bool {
    mimeType.contains("gzip") || mimeType.contains("tar") || mimeType.contains("zip")
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
