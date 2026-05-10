import AppKit
import SwiftUI

/// Pinterest-style masonry layout for the Collection navigation
/// context. Tiles preserve their natural aspect ratio (no cropping)
/// and pack into the shortest available column.
///
/// Phase A: column count is derived from available width, items are
/// distributed shortest-column-first. Aspect ratios come from the
/// canonical thumbnails — items without thumbnails default to 1:1
/// so they don't dominate the column.
struct MasonryGrid: View {
    @Environment(StashStore.self) private var store
    let items: [StashItem]
    /// Triggered on tile click. Caller wires this to selection.
    let onTap: (StashItem) -> Void
    /// Triggered on tile double-click — opens the item in its
    /// default app / browser, matching list and grid behavior.
    let onOpen: (StashItem) -> Void
    /// Right-click context menu builder, mirroring the list/grid
    /// row's menu so the Tags / Open / Edit / Delete actions are
    /// consistent across all view modes.
    let contextMenuBuilder: (String) -> AnyView
    /// Pure: comma-joined ids for `.draggable(_:)`. Side-effect free
    /// because the modifier may invoke this on mouseDown, before any
    /// drag actually starts. Sidebar drops split on `,`.
    let dragString: (String) -> String
    /// Triggered when items are dropped on a tile — caller reorders
    /// the curated collection so the dropped ids land just before
    /// the target id. Nil means drag-reorder is disabled (e.g. the
    /// user is in masonry mode but not navigated to a collection).
    let onReorderBefore: ((Set<String>, String) -> Void)?

    /// ID of the tile currently being hovered as a drop target, or
    /// nil. Drives the live-reflow preview: items recompute as if
    /// the dragged ids were inserted before this tile.
    @State private var hoverTargetID: String?

    /// Items reordered as if the drop happened now. When the user
    /// is hovering a target with a non-empty drag payload that
    /// includes items in this collection, surrounding tiles reflow
    /// to show the proposed placement. Otherwise returns `items`
    /// unchanged.
    private var displayItems: [StashItem] {
        guard let target = hoverTargetID,
              onReorderBefore != nil,
              !store.draggingItemIDs.isEmpty else {
            return items
        }
        let dragged = store.draggingItemIDs
        // Hovering own tile is a no-op — leave the layout alone.
        if dragged.contains(target) { return items }
        let filtered = items.filter { !dragged.contains($0.id) }
        let draggedItems = items.filter { dragged.contains($0.id) }
        guard !draggedItems.isEmpty else { return items }
        var preview: [StashItem] = []
        var inserted = false
        for it in filtered {
            if it.id == target && !inserted {
                preview.append(contentsOf: draggedItems)
                inserted = true
            }
            preview.append(it)
        }
        if !inserted {
            preview.append(contentsOf: draggedItems)
        }
        return preview
    }

    var body: some View {
        GeometryReader { proxy in
            let columnCount = preferredColumnCount(for: proxy.size.width)
            ScrollView {
                let buckets = distribute(displayItems, columns: columnCount)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<columnCount, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(buckets[idx]) { entry in
                                tile(for: entry)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(14)
            }
        }
        // Clear the preview state when the drag ends — relying on
        // per-tile `isTargeted: false` callbacks would flicker
        // (multiple tiles toggle in quick succession as the cursor
        // crosses gaps). The store's drag flag flips back to empty
        // on mouseUp via its NSEvent monitor.
        .onChange(of: store.draggingItemIDs.isEmpty) { _, isEmpty in
            if isEmpty { hoverTargetID = nil }
        }
    }

    /// Single tile + its draggable + drop target wrapping. When
    /// `onReorderBefore` is set (collection navigation), each tile
    /// also accepts drops to insert the dropped ids before this
    /// tile's item — that's the drag-to-reorder UX. Hover state is
    /// reported up to MasonryGrid so the live-reflow preview can
    /// reorder all tiles, not just the hovered one.
    ///
    /// When a reflow preview is active and this tile is one of the
    /// dragged items, render it as a ghost (low opacity + dashed
    /// outline) so the user can tell at a glance which tile is the
    /// drop placeholder vs. the original tiles.
    @ViewBuilder
    private func tile(for entry: Entry) -> some View {
        let isGhostPreview = hoverTargetID != nil
            && store.draggingItemIDs.contains(entry.item.id)
        MasonryTile(item: entry.item, aspectRatio: entry.aspect)
            .opacity(isGhostPreview ? 0.6 : 1.0)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .padding(-2)
                    .opacity(isGhostPreview ? 0.85 : 0)
            )
            .onTapGesture(count: 2) { onOpen(entry.item) }
            .onTapGesture { onTap(entry.item) }
            .draggable(dragString(entry.item.id))
            .contextMenu { contextMenuBuilder(entry.item.id) }
            .modifier(ReorderDropModifier(
                tileID: entry.item.id,
                hoverTargetID: hoverTargetID,
                onReorderBefore: onReorderBefore,
                onHoverChange: { isOver in
                    // Only set on enter, never reset on exit (avoids
                    // A.exit / B.enter flicker). And ignore hover
                    // events fired by the dragged tile itself —
                    // after a reflow the dragged tile slides into
                    // the cursor's screen position and would
                    // otherwise re-target itself, snapping the
                    // layout back. The drag-end watcher clears the
                    // state when mouse-up fires.
                    if isOver,
                       !store.draggingItemIDs.contains(entry.item.id) {
                        hoverTargetID = entry.item.id
                    }
                }
            ))
    }

    /// Aim for ~200pt-wide columns; clamp to 1...5 so very narrow or
    /// very wide windows still produce a sensible grid.
    private func preferredColumnCount(for width: CGFloat) -> Int {
        let target: CGFloat = 200
        let count = Int((width / target).rounded(.down))
        return max(1, min(count, 5))
    }

    /// Greedy shortest-column-first distribution. Tile "height" is
    /// approximated as `1/aspect` (column-width units) plus a small
    /// constant for the title — we don't need pixel-precision to get
    /// a balanced look, just relative magnitudes.
    private func distribute(
        _ items: [StashItem],
        columns: Int
    ) -> [[Entry]] {
        var buckets: [[Entry]] = Array(repeating: [], count: columns)
        var heights: [CGFloat] = Array(repeating: 0, count: columns)
        for item in items {
            let aspect = aspectRatio(for: item)
            let estimated = (1.0 / max(aspect, 0.2)) + 0.18
            let target = heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
            buckets[target].append(Entry(item: item, aspect: aspect))
            heights[target] += estimated
        }
        return buckets
    }

    private func aspectRatio(for item: StashItem) -> CGFloat {
        // Read from the shared thumbnail cache. The first masonry
        // render after a cold start sees cache misses and falls back
        // to 1.0 — the AsyncThumbnailImage in each tile populates
        // the cache as it decodes off-thread, and SwiftUI's state
        // change re-renders the grid with real aspect ratios on the
        // next pass. This matters because the previous inline
        // NSImage(contentsOf:) decode ran on the main thread for
        // every item in the grid on every layout pass — for a few
        // hundred items that was multi-second navigation lag.
        guard let rel = item.thumbnailPath,
              let url = FilePathResolver.resolveRelative(rel) else {
            return 1.0
        }
        if let cached = ThumbnailCache.shared.aspect(forPath: url.path) {
            return cached
        }
        // Kick off an async load so the cache populates and the
        // grid re-renders with the real aspect on the next pass.
        Task { await ThumbnailCache.shared.loadAsync(path: url.path) }
        return 1.0
    }

    private struct Entry: Identifiable {
        let item: StashItem
        let aspect: CGFloat
        var id: String { item.id }
    }
}

/// Wraps a tile with a `.dropDestination` for the curated-reorder
/// flow when `onReorderBefore` is non-nil. Reports hover state up
/// to the parent (MasonryGrid) which uses it to reflow the entire
/// layout to preview the proposed placement.
///
/// Drop uses `hoverTargetID` (the live preview anchor) instead of
/// this tile's own id. After a reflow, the cursor's screen position
/// can land over a tile that wasn't the user's intended target —
/// the preview shows the insertion before the *last hovered* tile,
/// so the drop must use the same anchor for them to match.
private struct ReorderDropModifier: ViewModifier {
    let tileID: String
    let hoverTargetID: String?
    let onReorderBefore: ((Set<String>, String) -> Void)?
    let onHoverChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if let onReorderBefore {
            content
                .dropDestination(for: String.self) { payloads, _ in
                    let ids = Set(
                        payloads
                            .flatMap { $0.split(separator: ",").map(String.init) }
                            .filter { !$0.isEmpty }
                    )
                    guard !ids.isEmpty else { return false }
                    let target = hoverTargetID ?? tileID
                    onReorderBefore(ids, target)
                    return true
                } isTargeted: { onHoverChange($0) }
        } else {
            content
        }
    }
}
