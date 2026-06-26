import SwiftUI
import UniformTypeIdentifiers
import CoreLocation

@MainActor
private final class ScrollOffsetTracker {
    var value: CGFloat = 0
}

struct ItemDetailView: View {
    @Environment(StashStore.self) private var store
    @Environment(AIPrefsStore.self) private var aiPrefs
    let item: StashItem
    @Binding var showEditSheet: Bool
    @State private var showDeleteConfirm = false
    @State private var showLinkSheet = false
    @State private var isFetchingContent = false
    @State private var showLocationMapPopover = false
    @State private var restoreMapPopoverOnPreviewDismiss = false
    @State private var isAddingTag = false
    @State private var newTagText = ""
    @State private var isAddingCollection = false
    @State private var newCollectionText = ""
    /// Tracks if the user has manually scrolled since pinning, to break the pin.
    @State private var hasScrolledSincePin = false
    @State private var lastScrollOffset = ScrollOffsetTracker()
    /// Inline-edit mode for the title. Double-click on the title
    /// flips this; commit / cancel routes through InlineEditField
    /// (X-inside-the-field + click-off saves, per the project's
    /// inline-edit convention).
    @State private var isEditingTitle = false
    @State private var titleDraft = ""

    private var pinnedViews: PinnedScrollableViews {
        if hasScrolledSincePin { return [] }
        if isAddingTag || isAddingCollection {
            return [.sectionHeaders]
        }
        return []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: pinnedViews) {
                    // Header
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: item.type.icon)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                HStack(spacing: 8) {
                                    titleView
                                    // Favorite toggle — inline with title so
                                    // it reads like Mail's flag or Photos'
                                    // heart (action sits on the thing it
                                    // affects, not in a separate toolbar
                                    // group). Filled yellow when on, hollow
                                    // gray otherwise. Keyboard shortcut F
                                    // (no modifier) when the detail view
                                    // has focus and no text field is active.
                                    let isFavorite = item.tags?.contains(where: { $0.name == FavoriteTag.name }) ?? false
                                    Button {
                                        store.setFavorite(itemID: item.id, favorite: !isFavorite)
                                    } label: {
                                        Image(systemName: isFavorite ? "star.fill" : "star")
                                            .font(.title3)
                                            .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .keyboardShortcut("f", modifiers: [])
                                    .help(isFavorite ? "Remove from favorites (F)" : "Mark as favorite (F)")

                                    // In-flight identify spinner mirrors the
                                    // list-row indicator so the user has a
                                    // visible signal that Stash is still
                                    // working when they pick "Identify with X"
                                    // from the right-click menu.
                                    if store.identifyingItemIDs.contains(item.id) {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                HStack(spacing: 4) {
                                    Text("\(String(item.type.label.dropLast())) \u{2022} \(item.shortID)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        let pb = NSPasteboard.general
                                        pb.clearContents()
                                        pb.setString(item.id, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy full ID")
                                    .onHover { hovering in
                                        if hovering { NSCursor.pointingHand.push() }
                                        else { NSCursor.pop() }
                                    }
                                }
                            }
                            Spacer()
                            ContextualHelpButton(topic: .itemTypes)
                        }

                        Divider()

                        // Unified media area — switches between embed-only,
                        // audio-beside-thumb, video tap-to-play, plain
                        // thumbnail, or hidden, based on item shape.
                        if item.files?.isEmpty != false {
                            MediaSection(item: item)
                        }
                    }
                    .padding(.bottom, 8)

                    // Media preview (Image, Multi-file, or Blob fallback).
                    if item.type == .image || (item.files?.isEmpty == false) {
                        DetailSection(title: "Preview") {
                            let primaryURL = item.storePath
                                .flatMap { FilePathResolver.resolve(storePath: $0) }
                            let thumbnailURL = (item.thumbnailPath?.isEmpty == false)
                                .takeIf { $0 == true }
                                .flatMap { _ in
                                    FilePathResolver.resolveRelative(item.thumbnailPath!)
                                }
                                .flatMap { url in
                                    FileManager.default.fileExists(atPath: url.path)
                                        ? url : nil
                                }
                            if let files = item.files, !files.isEmpty {
                                MultiFilePreview(item: item)
                            } else if let primary = primaryURL {
                                ImagePreviewSection(fileURL: primary)
                                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                        attachDroppedFiles(providers: providers)
                                    }
                            } else if let fallback = thumbnailURL {
                                VStack(alignment: .leading, spacing: 6) {
                                    ImagePreviewSection(fileURL: fallback)
                                    MissingBlobBanner(itemID: item.id)
                                }
                            } else {
                                MissingBlobBanner(itemID: item.id)
                            }
                        }
                    }

                    // URL
                    if let urlString = item.url, !urlString.isEmpty {
                        DetailSection(title: "URL") {
                            VStack(alignment: .leading, spacing: 8) {
                                ClickableURLText(urlString: urlString)
                                Button {
                                    NotificationCenter.default.post(
                                        name: .stashOpenFetchURL,
                                        object: nil,
                                        userInfo: ["url": urlString]
                                    )
                                } label: {
                                    Label("Fetch Files from this URL…", systemImage: "tray.and.arrow.down")
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    NotesView(text: item.notes ?? "", itemID: item.id)

                    if let loc = item.location {
                        DetailSection(title: "Location") {
                            locationRow(loc: loc)
                        }
                    }

                    SpeakerSection(item: item)

                    tagsSection(proxy: proxy)

                    collectionsSection(proxy: proxy)

                    RelatedSection(itemID: item.id)

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
                                    .pointingHandCursor()
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

                    DetailSection(title: "Info") {
                        InfoTable {
                            if let mime = item.mimeType {
                                InfoRow.row("MIME Type") { Text(mime).textSelection(.enabled) }
                            }
                            if let lang = item.language {
                                InfoRow.row("Language") {
                                    Text(lang)
                                        .font(.callout.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(.blue)
                                }
                            }
                            if let size = item.humanFileSize {
                                InfoRow.row("Size") { Text(size) }
                            }
                            if let source = item.sourcePath {
                                InfoRow.row("Source") {
                                    Text(source)
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                        .truncationMode(.middle)
                                }
                            }
                            if let captured = item.capturedAt {
                                InfoRow.row("Captured") {
                                    Text(captured.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            InfoRow.row("Created") {
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            InfoRow.row("Updated") {
                                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let cam = item.metadata?.camera, cam.hasAny {
                                if let device = cam.deviceLabel {
                                    InfoRow.row("Capture device") {
                                        Text(device).textSelection(.enabled)
                                    }
                                }
                                if let settings = cam.settingsLine {
                                    InfoRow.row("Settings") {
                                        Text(settings)
                                            .font(.callout.monospacedDigit())
                                            .textSelection(.enabled)
                                    }
                                }
                                if let dims = cam.dimensionsLine {
                                    InfoRow.row("Dimensions") {
                                        Text(dims).textSelection(.enabled)
                                    }
                                }
                                if let lens = cam.lens, !lens.isEmpty,
                                   lens != cam.deviceLabel {
                                    InfoRow.row("Lens") {
                                        Text(lens)
                                            .textSelection(.enabled)
                                            .lineLimit(2)
                                            .truncationMode(.tail)
                                    }
                                }
                            }
                        }
                    }

                    ProvenanceSection(itemID: item.id)

                    if let mime = item.mimeType, isArchiveMIME(mime),
                       let storePath = item.storePath,
                       let fileURL = FilePathResolver.resolve(storePath: storePath) {
                        ArchiveContentsView(fileURL: fileURL, mimeType: mime)
                    }

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
                                    .disabled(isFetchingContent)
                                }
                            }
                            if item.type == .email {
                                EmailContentView(text: text)
                            } else {
                                let isMedia = item.type == .file &&
                                    (item.mimeType?.hasPrefix("audio/") == true || item.mimeType?.hasPrefix("video/") == true)
                                ExtractedTextView(
                                    text: text,
                                    itemID: item.id,
                                    sectionTitle: isMedia ? "Transcript" : "Extracted Text",
                                    editorTitle: isMedia ? "Edit Transcript" : "Edit Extracted Text"
                                )
                            }
                        }
                    } else if item.type == .url {
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
                                        ProgressView().controlSize(.small)
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
                }
                .padding()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named("scroll")).minY
                } action: { newValue in
                    if (isAddingTag || isAddingCollection) && !hasScrolledSincePin {
                        let delta = abs(newValue - lastScrollOffset.value)
                        if delta > 1.0 {
                            hasScrolledSincePin = true
                        }
                    }
                    lastScrollOffset.value = newValue
                }
            }
            .coordinateSpace(name: "scroll")
            .helpAnchor(.itemDetail)
            .onReceive(NotificationCenter.default.publisher(for: .stashOpenFetchURL)) { note in
                if let url = note.userInfo?["url"] as? String, url == item.url {
                    refetchContent()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .imagePreviewDismissed)) { _ in
                if restoreMapPopoverOnPreviewDismiss {
                    restoreMapPopoverOnPreviewDismiss = false
                    showLocationMapPopover = true
                }
            }
        }
        .onAppear { store.markSeen(item.id) }
        .toolbar {
            ToolbarItemGroup {
                Button { showLinkSheet = true } label: {
                    Label("Link...", systemImage: "link")
                }
                .keyboardShortcut("l", modifiers: .command)
                Button {
                    if let current = store.selectedItem {
                        store.openItem(id: current.id)
                    }
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .keyboardShortcut("o", modifiers: .command)
                
                let isVideo = item.type == .file && item.mimeType?.hasPrefix("video/") == true
                if item.type == .image || item.type == .snippet || isVideo {
                    Button {
                        openGoogleSearch(for: item)
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                
                if item.archived == true {
                    Button {
                        store.unarchiveItems(ids: [item.id])
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                }
                
                ShareButton(item: { item })
                    .frame(width: 22, height: 22)
                Button { showEditSheet = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                Button { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            LinkItemSheet(sourceItemID: item.id)
        }
        .dropDestination(for: String.self) { items, _ in
            let rawIds = items.flatMap { $0.split(separator: ",").map(String.init) }
            let filteredIds = rawIds.filter { id in
                !id.isEmpty && id != item.id && !id.contains(where: { $0.isWhitespace }) && id.count <= 40
            }
            guard let droppedID = filteredIds.first else { return false }
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

    @ViewBuilder
    private func tagsSection(proxy: ScrollViewProxy) -> some View {
        Section {
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
                            if hovering { NSCursor.pointingHand.push() }
                            else { NSCursor.pop() }
                        }
                    }
                }

                if isAddingTag {
                    InlineTagInput(
                        text: $newTagText,
                        allTags: store.tags,
                        onBeginEditing: {
                            hasScrolledSincePin = false
                            withAnimation(.spring(duration: 0.3)) {
                                proxy.scrollTo("tags-section", anchor: .top)
                            }
                        },
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
            .padding(.leading, 14)
            .padding(.bottom, 8)
            .background(Color(NSColor.windowBackgroundColor))
        } header: {
            HStack(spacing: 4) {
                Text("Tags")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .id("tags-section")
    }

    @ViewBuilder
    private func collectionsSection(proxy: ScrollViewProxy) -> some View {
        Section {
            FlowLayout(spacing: 6) {
                if let cols = item.collections {
                    ForEach(cols) { col in
                        Label(col.name, systemImage: "folder")
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
                
                if isAddingCollection {
                    InlineCollectionInput(
                        text: $newCollectionText,
                        allCollections: store.collections,
                        onBeginEditing: {
                            hasScrolledSincePin = false
                            withAnimation(.spring(duration: 0.3)) {
                                proxy.scrollTo("collections-section", anchor: .top)
                            }
                        },
                        onCommit: { input in
                            let names = input.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            if !names.isEmpty {
                                store.addCollectionsToItem(id: item.id, collections: names)
                            }
                            newCollectionText = ""
                            isAddingCollection = false
                        },
                        onCancel: {
                            newCollectionText = ""
                            isAddingCollection = false
                        }
                    )
                } else {
                    Button {
                        isAddingCollection = true
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
            .padding(.leading, 14)
            .padding(.bottom, 8)
            .background(Color(NSColor.windowBackgroundColor))
        } header: {
            HStack(spacing: 4) {
                Text("Collections")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .id("collections-section")
    }

    private func locationRow(loc: ItemLocation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary)
            Text(String(format: "%.6f, %.6f", loc.lat, loc.lon))
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
            Button {
                showLocationMapPopover = true
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showLocationMapPopover, arrowEdge: .top) {
                let primaryURL = item.storePath.flatMap { FilePathResolver.resolve(storePath: $0) }
                LocationMapPopover(lat: loc.lat, lon: loc.lon, primaryURL: primaryURL, additionalPoints: getAdditionalLocations(fallbackLat: loc.lat, fallbackLon: loc.lon)) {
                    restoreMapPopoverOnPreviewDismiss = true
                }
            }
            if let url = item.mapsURL {
                Link("Open in Maps", destination: url)
                    .font(.caption)
            }
            if let src = loc.source, !src.isEmpty {
                Text(src)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func getAdditionalLocations(fallbackLat: Double, fallbackLon: Double) -> [LocationPoint] {
        var points: [LocationPoint] = []
        if let files = item.files {
            for f in files {
                if let url = FilePathResolver.resolve(storePath: f.storePath) {
                    let coord = ImageProcessor.extractLocation(from: url) ?? CLLocationCoordinate2D(latitude: fallbackLat, longitude: fallbackLon)
                    points.append(LocationPoint(id: f.caption ?? "File \(f.position)", coord: coord, url: url))
                }
            }
        }
        return points
    }

    private func attachDroppedFiles(providers: [NSItemProvider]) -> Bool {
        var attached = 0
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                let path = url.path(percentEncoded: false)
                Task { @MainActor in
                    store.attachFile(to: item.id, path: path)
                }
            }
            attached += 1
        }
        return attached > 0
    }

    private func refetchContent() {
        isFetchingContent = true
        store.refetchURLContent(id: item.id)
        Task {
            try? await Task.sleep(for: .seconds(3))
            isFetchingContent = false
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            InlineEditField(
                text: $titleDraft,
                placeholder: "Title",
                onCommit: commitTitleEdit,
                onCancel: cancelTitleEdit
            )
            .font(.title2)
            .fontWeight(.semibold)
        } else {
            Text(item.title)
                .font(.title2)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .background(ClickCatcher(onDoubleClick: startTitleEdit))
        }
    }

    private func startTitleEdit() {
        titleDraft = item.title
        isEditingTitle = true
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingTitle = false
            return
        }
        if trimmed != item.title {
            store.editItem(id: item.id, title: trimmed, note: nil, addTags: [], removeTags: [], collection: nil)
        }
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
    }

    private func openGoogleSearch(for item: StashItem) {
        Task {
            var q = item.title
            if item.type == .snippet, let text = item.extractedText, !text.isEmpty {
                q = "\"\(String(text.prefix(150)))\""
            } else if let loc = item.location {
                let clLoc = CoreLocation.CLLocation(latitude: loc.lat, longitude: loc.lon)
                if let placemarks = try? await CoreLocation.CLGeocoder().reverseGeocodeLocation(clLoc),
                   let place = placemarks.first {
                    let parts = [place.administrativeArea, place.country].compactMap { $0 }
                    q += " " + (parts.isEmpty ? "\(loc.lat), \(loc.lon)" : parts.joined(separator: ", "))
                } else {
                    q += " \(loc.lat), \(loc.lon)"
                }
            }
            await MainActor.run {
                var comps = URLComponents(string: "https://www.google.com/search")
                comps?.queryItems = [URLQueryItem(name: "q", value: q)]
                if let searchURL = comps?.url { NSWorkspace.shared.open(searchURL) }
            }
        }
    }
}

// MARK: - Components

struct DetailSection<Content: View>: View {
    let title: String
    var showIndicator: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                if showIndicator { Circle().fill(Color.blue).frame(width: 6, height: 6) }
            }
            content.padding(.leading, 14)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

struct InfoTable: View {
    let rows: [InfoRow]
    init(@InfoRowBuilder _ rows: () -> [InfoRow]) { self.rows = rows() }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label).font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                    row.value.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(idx.isMultiple(of: 2) ? Color.secondary.opacity(0.08) : Color.clear)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

@resultBuilder
enum InfoRowBuilder {
    static func buildBlock(_ groups: [InfoRow]...) -> [InfoRow] { groups.flatMap { $0 } }
    static func buildOptional(_ rows: [InfoRow]?) -> [InfoRow] { rows ?? [] }
    static func buildEither(first rows: [InfoRow]) -> [InfoRow] { rows }
    static func buildEither(second rows: [InfoRow]) -> [InfoRow] { rows }
    static func buildExpression(_ row: InfoRow) -> [InfoRow] { [row] }
    static func buildExpression(_ rows: [InfoRow]) -> [InfoRow] { rows }
    static func buildArray(_ rows: [[InfoRow]]) -> [InfoRow] { rows.flatMap { $0 } }
}

struct InfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: AnyView
    init<V: View>(label: String, @ViewBuilder value: () -> V) {
        self.label = label
        self.value = AnyView(value())
    }
    static func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> InfoRow {
        InfoRow(label: label, value: value)
    }
}

struct MissingBlobBanner: View {
    @Environment(StashStore.self) private var store
    let itemID: String
    @State private var healing = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("File content is missing from local storage.").font(.subheadline)
            Spacer()
            Button(healing ? "Healing..." : "Heal") {
                healing = true
                Task { await store.healItem(id: itemID); healing = false }
            }.buttonStyle(.bordered).controlSize(.small).disabled(healing)
        }.padding(10).background(.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension Bool {
    func takeIf(_ predicate: (Bool) -> Bool) -> Bool? { predicate(self) ? self : nil }
}

/// Helper to identify audio MIME types across the app.
func isAudioMIME(_ mime: String) -> Bool {
    mime.hasPrefix("audio/") || mime == "application/ogg" || mime == "application/x-flac" || mime.contains("m4a")
}

func isArchiveMIME(_ mime: String) -> Bool {
    mime.contains("gzip") || mime.contains("tar") || mime.contains("zip") || 
    mime == "application/x-bzip2" || mime == "application/x-7z-compressed"
}
