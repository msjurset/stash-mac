import SwiftUI

struct ItemDetailView: View {
    @Environment(StashStore.self) private var store
    let item: StashItem
    @Binding var showEditSheet: Bool
    @State private var showDeleteConfirm = false
    @State private var showLinkSheet = false
    @State private var isFetchingContent = false
    @State private var isAddingTag = false
    @State private var newTagText = ""

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
                        Text(urlString)
                            .foregroundStyle(.blue)
                            .textSelection(.enabled)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onTapGesture {
                                if let url = URL(string: urlString) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
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
                DetailSection(title: "Tags") {
                    FlowLayout(spacing: 6) {
                        if let tags = item.tags {
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

                        if isAddingTag {
                            InlineTagInput(
                                text: $newTagText,
                                allTags: store.tags,
                                onCommit: { input in
                                    let tags = input.split(separator: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                    if !tags.isEmpty {
                                        store.addTagsToItem(id: item.id, tags: tags)
                                    }
                                    newTagText = ""
                                    isAddingTag = false
                                },
                                onCancel: {
                                    newTagText = ""
                                    isAddingTag = false
                                }
                            )
                        } else {
                            Button {
                                isAddingTag = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
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
                if item.mimeType != nil || item.fileSize != nil || item.language != nil {
                    DetailSection(title: "File Info") {
                        if let mime = item.mimeType {
                            LabeledContent("MIME Type", value: mime)
                        }
                        if let lang = item.language {
                            LabeledContent("Language") {
                                Text(lang)
                                    .font(.callout.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.blue)
                            }
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
                    VStack(alignment: .leading, spacing: 0) {
                        if item.type == .url {
                            HStack {
                                Spacer()
                                Button {
                                    refetchContent()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Re-fetch page content")
                                .disabled(isFetchingContent)
                            }
                        }
                        if item.type == .email {
                            EmailContentView(text: text)
                        } else {
                            ExtractedTextView(text: text)
                        }
                    }
                } else if item.type == .url {
                    // URL with no extracted text — offer to fetch
                    DetailSection(title: "Extracted Text") {
                        HStack {
                            Text("No content extracted")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                refetchContent()
                            } label: {
                                if isFetchingContent {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Fetch", systemImage: "arrow.clockwise")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isFetchingContent)
                        }
                    }
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
                .help("Link to another item (⌘L)")
                Button {
                    if let current = store.selectedItem {
                        store.openItem(id: current.id)
                    }
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Open in default application (⌘O)")
                Button { showEditSheet = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .help("Edit item (⌘E)")
                Button { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Delete item (⌘⌫)")
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
        .onAppear { store.markSeen(item.id) }
        .confirmationDialog("Delete \"\(item.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                store.deleteItem(id: item.id)
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func refetchContent() {
        isFetchingContent = true
        store.refetchURLContent(id: item.id)
        // Reset after a delay to allow the store to reload
        Task {
            try? await Task.sleep(for: .seconds(3))
            isFetchingContent = false
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
