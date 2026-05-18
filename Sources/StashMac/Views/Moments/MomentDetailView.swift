import AppKit
import ImageIO
import SwiftUI

/// Right-pane viewer for the Moments sidebar entry. Reads
/// `store.selectedMoment` and renders the cluster's items as
/// an adaptive grid of thumbnails. Click any tile to jump into that
/// item's detail (switches sidebar nav to All Items and selects).
///
/// The grid is the user's "did I cluster the right things?" check
/// before they hit Accept on the middle-pane card. No state of its
/// own — the suggestion's `items` array already carries every
/// (id, title, type, thumbnail_path) tuple needed to draw.
struct MomentDetailView: View {
    @Environment(StashStore.self) private var store

    var body: some View {
        if let suggestion = store.selectedMoment {
            VStack(alignment: .leading, spacing: 0) {
                header(for: suggestion)
                Divider()
                ScrollView {
                    LazyVGrid(
                        // alignment: .top so a row with mixed
                        // single-line and wrapped two-line captions
                        // top-anchors every image — the default
                        // center alignment otherwise pushed the
                        // single-line tile's image down to match the
                        // two-line tile's overall height, leaving
                        // images visibly misaligned across the row.
                        columns: [GridItem(.adaptive(minimum: 160),
                                           spacing: 16,
                                           alignment: .top)],
                        spacing: 16
                    ) {
                        ForEach(suggestion.items, id: \.id) { item in
                            DetailTile(
                                item: item,
                                isSelected: store.selectedMomentItemIDs.contains(item.id),
                                onToggle: { toggle(itemID: item.id) },
                                onOpen: { openInList(itemID: item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Reset selection to "everything" whenever the focused
            // suggestion changes, so a fresh click on a card in the
            // middle pane shows the cluster as a fresh draft instead
            // of carrying the prior selection forward.
            .onChange(of: suggestion.id) { _, _ in
                store.selectedMomentItemIDs = Set(suggestion.items.map(\.id))
            }
            .onAppear {
                if store.selectedMomentItemIDs.isEmpty {
                    store.selectedMomentItemIDs = Set(suggestion.items.map(\.id))
                }
            }
        } else {
            // No selection — guide the user to the middle pane.
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Select a trip suggestion")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Click a card on the left to preview its items.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    @ViewBuilder
    private func header(for suggestion: StashCLI.MomentSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.suggestedName)
                    .font(.title3.weight(.semibold))
                Text(selectionSummary(for: suggestion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Match the middle-pane header's reserved
                    // 2-line subtitle so the panes' bottom edges
                    // line up against the same divider regardless
                    // of how long the subtitle actually is.
                    .lineLimit(2, reservesSpace: true)
            }
            Spacer()
            // Bulk toggle: flips between "select all" and "deselect
            // all" depending on what's selected right now. Cheaper
            // than two buttons for the common "I want everything"
            // and "I want to start fresh" pivots.
            Button(allSelected(suggestion) ? "Deselect all" : "Select all") {
                if allSelected(suggestion) {
                    store.selectedMomentItemIDs.removeAll()
                } else {
                    store.selectedMomentItemIDs = Set(suggestion.items.map(\.id))
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func allSelected(_ suggestion: StashCLI.MomentSuggestion) -> Bool {
        let ids = Set(suggestion.items.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: store.selectedMomentItemIDs)
    }

    private func selectionSummary(for suggestion: StashCLI.MomentSuggestion) -> String {
        let total = suggestion.items.count
        let selected = suggestion.items.filter { store.selectedMomentItemIDs.contains($0.id) }.count
        if selected == total {
            return "\(total) items"
        }
        return "\(selected) of \(total) selected"
    }

    private func toggle(itemID: String) {
        if store.selectedMomentItemIDs.contains(itemID) {
            store.selectedMomentItemIDs.remove(itemID)
        } else {
            store.selectedMomentItemIDs.insert(itemID)
        }
    }

    /// Navigate to the underlying item in the main list. Switches
    /// the sidebar to All Items (so the item is reachable regardless
    /// of how the user previously had it filtered) and asks the
    /// store to select + reveal it. Records the current Moments state
    /// onto the back-stack first so the toolbar Back button (or ⌘[)
    /// returns the user to the same suggestion + per-item selection
    /// they were reviewing.
    private func openInList(itemID: String) {
        store.recordNavigationHistory()
        store.applyNavigation(.allItems)
        store.selectItemByID(itemID, revealInList: true)
    }
}

// MARK: - Tile

private struct DetailTile: View {
    let item: StashCLI.MomentSuggestion.MomentItem
    let isSelected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        // Two independent click targets:
        //   - checkmark badge in the top-left → toggles selection
        //   - everything else on the tile → opens the item
        // Right-click surfaces both as menu items so the affordance
        // is discoverable even when the user doesn't notice the
        // small badge. Reverted from "whole tile toggles" because
        // the open-item drill-down is the primary verb users reach
        // for; gating it behind right-click added friction.
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    // Force a square tile regardless of the source
                    // image's aspect ratio. A Color.clear .frame() +
                    // .aspectRatio(1, .fit) makes a square spacer
                    // sized to the column width; overlaying the
                    // preview and clipping inside the rounded rect
                    // crops fill content into that square. Without
                    // this, a 4:3 portrait image's tile rendered
                    // taller than its landscape neighbors and rows
                    // visually crashed into each other.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            MomentPreviewImage(item: item)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected
                                            ? Color.accentColor.opacity(0.7)
                                            : Color.secondary.opacity(0.25),
                                        lineWidth: isSelected ? 1.5 : 1)
                        )
                        .opacity(isSelected ? 1.0 : 0.4)

                    selectionBadge
                        .padding(6)
                }

                Text(item.title?.isEmpty == false ? item.title! : item.id)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open Item") { onOpen() }
            Divider()
            Button(isSelected ? "Exclude from Collection" : "Include in Collection") {
                onToggle()
            }
        }
        .help(item.title?.isEmpty == false ? item.title! : item.id)
    }

    /// Filled checkmark when included, hollow circle when excluded.
    /// Wrapped in a Button so it consumes its own click region
    /// before the outer Button (whose job is to open the item)
    /// sees it — separate hit targets, no modifier-key dance.
    private var selectionBadge: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.45))
                    .frame(width: 22, height: 22)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(isSelected
                ? "Exclude from collection"
                : "Include in collection")
    }
}

/// Thumbnail-with-fallback for trip preview tiles. Resolution order:
///   1. `thumbnailPath` via the existing thumbnail cache (relative
///      path under filesDir, populated for items that have run
///      through `stash thumbnail backfill`).
///   2. `storePath` via FilePathResolver (the original content blob)
///      — only attempted for image items; rendering a video / PDF
///      blob inline isn't useful.
///   3. Type-emoji placeholder.
///
/// Step 2 is the critical fallback: older image captures predate
/// thumbnail-backfill and have a nil `thumbnailPath`. Their actual
/// JPEGs are still on disk and look fine at 160pt; falling back to
/// them avoids a "🖼️ everywhere" placeholder fog while still nudging
/// the user toward `stash thumbnail backfill` long-term.
private struct MomentPreviewImage: View {
    let item: StashCLI.MomentSuggestion.MomentItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.15))
                    Text(iconFor(type: item.type))
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: cacheKey) {
            image = await loadPreview()
        }
    }

    /// Per-item cache key for `.task(id:)`. Combines the hint inputs
    /// so a refresh that replaces an item's thumbnail re-fires the
    /// load instead of holding a stale image.
    private var cacheKey: String {
        (item.thumbnailPath ?? "") + "|" + (item.storePath ?? "") + "|" + (item.type ?? "")
    }

    private func loadPreview() async -> NSImage? {
        // Step 1: try the cached thumbnail. Goes through the shared
        // cache so first render in a session pays the decode once.
        if let rel = item.thumbnailPath,
           !rel.isEmpty,
           let url = FilePathResolver.resolveRelative(rel),
           FileManager.default.fileExists(atPath: url.path) {
            if let cached = ThumbnailCache.shared.image(forPath: url.path) {
                return cached
            }
            if let loaded = await ThumbnailCache.shared.loadAsync(path: url.path) {
                return loaded
            }
        }
        // Step 2: image item with a content blob — render the blob
        // directly via CGImageSource so the EXIF orientation tag is
        // honored. NSImage(contentsOf:) silently ignores EXIF
        // rotation for many camera-roll JPEGs, which left portrait
        // captures rendering on their side in the grid.
        if item.type == "image",
           let sp = item.storePath,
           !sp.isEmpty,
           let url = FilePathResolver.resolve(storePath: sp) {
            return await Task.detached(priority: .userInitiated) {
                Self.loadOriented(from: url)
            }.value
        }
        return nil
    }

    /// Load an NSImage with EXIF orientation pre-applied. Uses
    /// `kCGImageSourceCreateThumbnailWithTransform` so the returned
    /// CGImage is already rotated to its display orientation; the
    /// wrapping NSImage then renders correctly anywhere we draw it
    /// without needing per-call-site orientation handling.
    /// `MaxPixelSize` caps the decode at 1024px on the longest edge
    /// — the tile is ~160pt, so anything larger is wasted memory
    /// and decode time.
    nonisolated private static func loadOriented(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg,
                       size: NSSize(width: cg.width, height: cg.height))
    }

    private func iconFor(type: String?) -> String {
        switch type {
        case "image":   return "🖼️"
        case "url":     return "🌐"
        case "file":    return "📁"
        case "snippet": return "📄"
        case "email":   return "✉️"
        default:        return "•"
        }
    }
}
