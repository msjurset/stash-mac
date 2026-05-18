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
                AsyncThumbnailImage(
                    relativePath: item.thumbnailPath,
                    fallback: {
                        ZStack {
                            Rectangle().fill(.secondary.opacity(0.15))
                            Text(iconFor(type: item.type))
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                        }
                    }
                )
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
