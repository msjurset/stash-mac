import SwiftUI

/// Square thumbnail tile used by the grid view. Reuses the canonical
/// thumbnail when present; falls back to a tinted placeholder with
/// the type icon. Title sits beneath the tile, two lines max so the
/// grid stays uniform when titles vary in length.
struct ItemTile: View {
    @Environment(StashStore.self) private var store
    let item: StashItem

    private var isSelected: Bool {
        store.selectedItems.contains(item.id)
    }

    private var isUnseen: Bool {
        store.isUnseen(item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tile
            title
        }
        // Bound hit-testing to the tile's layout rectangle. Without
        // this, an overflowing thumbnail (e.g. an unusually wide
        // imported image rendered with `aspectRatio(.fill)`) extends
        // its hit area beyond the visible cell — clipShape clips the
        // visuals but not the hit-test, so a neighbouring tile's tap
        // routes to the overflowing tile's view. Setting an explicit
        // rectangular content shape keeps clicks landing on the
        // intended cell only.
        .contentShape(Rectangle())
    }

    /// Use a clear shape sized to a 1:1 aspect ratio as the bounding
    /// box, layer everything else as overlays, and clip the *whole*
    /// stack at the outer level. Without this anchor, oversize images
    /// escape their cell and bleed across the grid.
    private var tile: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(thumbnailLayer)
            .overlay(typeBadge, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .quaternaryLabelColor),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        AsyncThumbnailImage(
            relativePath: item.thumbnailPath,
            fallback: { TypeStyledPlaceholder(item: item) }
        )
    }

    private var typeBadge: some View {
        Image(systemName: item.type.icon)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.5), in: Circle())
            .padding(6)
    }

    private var title: some View {
        Text(item.title)
            .font(.callout)
            .fontWeight(isUnseen ? .semibold : .regular)
            .foregroundStyle(isUnseen ? .blue : .primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

}
