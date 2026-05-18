import SwiftUI
import UniformTypeIdentifiers

struct ItemDetailView: View {
    @Environment(StashStore.self) private var store
    let item: StashItem
    @Binding var showEditSheet: Bool
    @State private var showDeleteConfirm = false
    @State private var showLinkSheet = false
    @State private var isFetchingContent = false
    @State private var showLocationMapPopover = false
    @State private var isAddingTag = false
    @State private var newTagText = ""
    /// Inline-edit mode for the title. Double-click on the title
    /// flips this; commit / cancel routes through InlineEditField
    /// (X-inside-the-field + click-off saves, per the project's
    /// inline-edit convention).
    @State private var isEditingTitle = false
    @State private var titleDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: item.type.icon)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        titleView
                        HStack(spacing: 4) {
                            Text(item.type.label.dropLast() + " \u{2022} " + item.shortID)
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
                }

                Divider()

                // Unified media area — switches between embed-only,
                // audio-beside-thumb, video tap-to-play, plain
                // thumbnail, or hidden, based on item shape. Section
                // title intentionally absent — the visual labels
                // itself.
                MediaSection(item: item)

                // Image preview — full-resolution decoded off-thread
                // (see ImagePreviewSection) so navigating to a large
                // image item doesn't stall the runloop on
                // NSImage(contentsOf:) inside the body.
                if item.type == .image {
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
                            // Items with attached files render a
                            // carousel + filmstrip; single-file items
                            // stay on the lean ImagePreviewSection so we
                            // don't pay the LazyHStack / drop-target
                            // overhead on the 99% case. MultiFilePreview
                            // owns the missing-primary-blob fallback for
                            // these items (cached thumbnail + heal
                            // banner when every slot has lost its blob).
                            MultiFilePreview(item: item)
                        } else if let primary = primaryURL {
                            ImagePreviewSection(fileURL: primary)
                                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                    attachDroppedFiles(providers: providers)
                                }
                        } else if let fallback = thumbnailURL {
                            // Primary blob is missing on disk (rare —
                            // a `stash heal` or re-import will bring
                            // it back). Render the cached thumbnail so
                            // the user can still see what the item is.
                            VStack(alignment: .leading, spacing: 6) {
                                ImagePreviewSection(fileURL: fallback)
                                MissingBlobBanner(itemID: item.id)
                            }
                        } else {
                            // Neither primary blob nor thumbnail —
                            // surface the missing-blob warning so the
                            // user knows the item needs healing.
                            MissingBlobBanner(itemID: item.id)
                        }
                    }
                }

                // URL
                if let urlString = item.url, !urlString.isEmpty {
                    DetailSection(title: "URL") {
                        VStack(alignment: .leading, spacing: 8) {
                            ClickableURLText(urlString: urlString)
                            // Single-click affordance to walk the page
                            // for images / files. Routes through the
                            // same FetchURLSheet as the toolbar /
                            // File menu, just pre-populated.
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
                            .help("Discover images and files on this page and stash them as separate items.")
                        }
                    }
                }

                // Notes — Markdown-rendered, with double-click to
                // open a full popout editor (mirrors Extracted Text).
                // Long notes truncate to 500 chars with Show More;
                // single click toggles expand when truncated.
                if let notes = item.notes, !notes.isEmpty {
                    NotesView(text: notes, itemID: item.id)
                }

                // Location — only shown when an item has a stored
                // latitude/longitude (auto-extracted from EXIF on
                // ingest, set on mobile capture, or typed manually).
                if let loc = item.location {
                    DetailSection(title: "Location") {
                        locationRow(loc: loc)
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

                // Related Items — computed from tag/link/domain/hash
                // overlap. Distinct from "Linked Items" which is the
                // user's explicit set; this is the serendipitous
                // neighbor list. Section hides itself when empty.
                RelatedSection(itemID: item.id)

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

                // Info — file metadata (when present) plus ID and
                // timestamps, always shown. Single section replaces
                // the previous "File Info" + "Dates" split since
                // every item has an ID and dates and the file-only
                // fields read fine alongside them.
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
                        // "Captured" sits above "Created" because in the
                        // photo-heavy case it's what users actually want
                        // to see — when the shutter fired, not when the
                        // row landed in the stash. Shown only when
                        // populated (URL items leave it nil; older
                        // captures pre-backfill also nil).
                        if let captured = item.capturedAt {
                            InfoRow.row("Captured") {
                                Text(captured.formatted(date: .abbreviated, time: .shortened))
                                    .help("From EXIF / email headers / file mtime. Distinct from Created (when the row landed in this stash).")
                            }
                        }
                        InfoRow.row("Created") {
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        InfoRow.row("Updated") {
                            Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }

                // Provenance — capture / rule / tag timeline reconstructed
                // from capture.log and tags.log. Sits right after Info
                // because both sections are "metadata about the item"
                // rather than the item's content.
                ProvenanceSection(itemID: item.id)

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
                            ExtractedTextView(text: text, itemID: item.id)
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
                ShareButton(items: { SharePayload.build(for: item) })
                    .frame(width: 22, height: 22)
                    .help("Share via Mail, Messages, AirDrop, etc.")
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
            // Drag payloads are now comma-joined for multi-select
            // support; the link path takes one source-of-truth id,
            // so use the first non-self id from the bundle.
            let ids = items
                .flatMap { $0.split(separator: ",").map(String.init) }
                .filter { !$0.isEmpty && $0 != item.id }
            guard let droppedID = ids.first else { return false }
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

    /// Renders the single Location row: pin glyph + lat/lon (six
    /// decimal places ≈ 11cm precision, plenty), a crosshair button
    /// that pops up a MapKit preview with a pin, jump-out links to
    /// Apple / Google Maps, and a small source badge so the user
    /// can tell at a glance whether the value came from EXIF,
    /// mobile capture, or a manual edit.
    @ViewBuilder
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
            .help("Preview on a map")
            .popover(isPresented: $showLocationMapPopover, arrowEdge: .top) {
                LocationMapPopover(lat: loc.lat, lon: loc.lon)
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

    /// Single-file preview's drop-target callback. Promotes the
    /// item from "one file" to "carousel" by attaching the dropped
    /// file(s) as additional slides. The store refresh will swap
    /// the rendered view from ImagePreviewSection to MultiFilePreview
    /// on the next pass.
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
        // Reset after a delay to allow the store to reload
        Task {
            try? await Task.sleep(for: .seconds(3))
            isFetchingContent = false
        }
    }

    /// Detail-view title: read-only Text by default with a hover-
    /// revealed pencil button that flips into edit mode. Avoided
    /// View-mode title is plain Text; `ClickCatcher` lifts double-
    /// click into edit mode at the AppKit level so the second
    /// mouseDown is consumed before SwiftUI's gesture recognizer can
    /// cascade it onto the image preview's single-tap handler. The
    /// edit-mode `InlineEditField` auto-focuses on appear so the
    /// click-outside monitor inside it can resign first responder
    /// (and fire commitTitleEdit) when the user clicks away.
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
                .help("Double-click to edit")
        }
    }

    private func startTitleEdit() {
        titleDraft = item.title
        isEditingTitle = true
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty title is meaningless — silently drop the edit and
        // bail back to read mode rather than letting the user save
        // a blank title that's hard to recover.
        guard !trimmed.isEmpty else {
            isEditingTitle = false
            return
        }
        // No-op if unchanged.
        if trimmed != item.title {
            store.editItem(
                id: item.id,
                title: trimmed,
                note: nil,
                addTags: [],
                removeTags: [],
                collection: nil
            )
        }
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
    }

}

func isArchiveMIME(_ mimeType: String) -> Bool {
    mimeType.contains("gzip") || mimeType.contains("tar") || mimeType.contains("zip")
}

/// One label-value pair rendered inside `InfoTable`. The value is
/// retained as an `AnyView` so callers can hand in arbitrary content
/// (styled badges, multi-line text, etc.) without genericizing the
/// table builder.
struct InfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: AnyView

    static func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> InfoRow {
        InfoRow(label: label, value: AnyView(value()))
    }
}

/// Container that lays InfoRows out as a striped two-column table:
/// fixed-width label column on the left, flexible value column on
/// the right, alternating row backgrounds for scan-ability. Callers
/// hand in rows via a result-builder that filters out nils so each
/// row can be conditional (e.g. "show MIME only when set").
struct InfoTable: View {
    let rows: [InfoRow]

    init(@InfoRowBuilder _ rows: () -> [InfoRow]) {
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    row.value
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(idx.isMultiple(of: 2) ? Color.secondary.opacity(0.08) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Result-builder so InfoTable's body reads like a sequence of rows
/// with conditional `if let` blocks (same ergonomics as ViewBuilder).
/// Skips nil/empty branches automatically.
@resultBuilder
enum InfoRowBuilder {
    static func buildBlock(_ groups: [InfoRow]...) -> [InfoRow] {
        groups.flatMap { $0 }
    }
    static func buildOptional(_ rows: [InfoRow]?) -> [InfoRow] { rows ?? [] }
    static func buildEither(first rows: [InfoRow]) -> [InfoRow] { rows }
    static func buildEither(second rows: [InfoRow]) -> [InfoRow] { rows }
    static func buildExpression(_ row: InfoRow) -> [InfoRow] { [row] }
    static func buildExpression(_ rows: [InfoRow]) -> [InfoRow] { rows }
    static func buildArray(_ rows: [[InfoRow]]) -> [InfoRow] { rows.flatMap { $0 } }
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
                .padding(.leading, 14)
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

/// Banner shown when the primary content blob for an image item
/// is missing on disk. Surfaces the gap to the user along with a
/// "Heal" button that fires `stash heal <id>` to re-fetch from
/// the item's source URL when possible. Pairs with the existing
/// Health-Check workflow but appears in the detail pane itself
/// so the user notices immediately.
struct MissingBlobBanner: View {
    let itemID: String
    @Environment(StashStore.self) private var store
    @State private var isHealing = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Content file missing on disk")
                    .font(.callout.weight(.medium))
                Text("Showing the cached thumbnail. Heal to re-fetch the full file from the source URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isHealing = true
                Task {
                    await store.healItem(id: itemID)
                    isHealing = false
                }
            } label: {
                if isHealing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Heal")
                }
            }
            .disabled(isHealing)
        }
        .padding(10)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.yellow.opacity(0.4), lineWidth: 1)
        )
    }
}

private extension Bool {
    /// Compose-style `takeIf` for nullable chaining, used by the
    /// preview-section thumbnail fallback to keep the conditional
    /// pipeline readable.
    func takeIf(_ predicate: (Bool) -> Bool) -> Bool? {
        predicate(self) ? self : nil
    }
}
