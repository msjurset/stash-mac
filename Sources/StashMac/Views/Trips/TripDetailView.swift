import SwiftUI

/// Right-pane viewer for the Trips sidebar entry. Reads
/// `store.selectedTripSuggestion` and renders the cluster's items as
/// an adaptive grid of thumbnails. Click any tile to jump into that
/// item's detail (switches sidebar nav to All Items and selects).
///
/// The grid is the user's "did I cluster the right things?" check
/// before they hit Accept on the middle-pane card. No state of its
/// own — the suggestion's `items` array already carries every
/// (id, title, type, thumbnail_path) tuple needed to draw.
struct TripDetailView: View {
    @Environment(StashStore.self) private var store

    var body: some View {
        if let suggestion = store.selectedTripSuggestion {
            VStack(alignment: .leading, spacing: 0) {
                header(for: suggestion)
                Divider()
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(suggestion.items, id: \.id) { item in
                            DetailTile(item: item) {
                                openInList(itemID: item.id)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func header(for suggestion: StashCLI.TripSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(suggestion.suggestedName)
                .font(.title3.weight(.semibold))
            Text("\(suggestion.itemCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Navigate to the underlying item in the main list. Switches
    /// the sidebar to All Items (so the item is reachable regardless
    /// of how the user previously had it filtered) and asks the
    /// store to select + reveal it.
    private func openInList(itemID: String) {
        store.applyNavigation(.allItems)
        store.selectItemByID(itemID, revealInList: true)
    }
}

// MARK: - Tile

private struct DetailTile: View {
    let item: StashCLI.TripSuggestion.TripItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                TripPreviewImage(item: item)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                Text(item.title?.isEmpty == false ? item.title! : item.id)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(item.title?.isEmpty == false ? item.title! : item.id)
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
private struct TripPreviewImage: View {
    let item: StashCLI.TripSuggestion.TripItem
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
        // directly. Off main, same as the thumbnail cache path.
        if item.type == "image",
           let sp = item.storePath,
           !sp.isEmpty,
           let url = FilePathResolver.resolve(storePath: sp) {
            return await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
        return nil
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
