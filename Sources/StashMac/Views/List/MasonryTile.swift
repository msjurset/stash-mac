import SwiftUI

/// Single tile in the masonry grid. Aspect ratio is forced via a
/// `Color.clear` anchor so the image's intrinsic size doesn't bleed
/// across cells; the actual image is layered as an overlay and the
/// whole stack is clipped.
struct MasonryTile: View {
    @Environment(StashStore.self) private var store
    let item: StashItem
    /// Width / height of the canonical thumbnail. 1.0 = square.
    let aspectRatio: CGFloat

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
        // Same hit-test fix as ItemTile — clipShape clips visuals
        // but not hit-testing, so an oversized thumbnail can grab
        // clicks from neighbouring tiles. Explicitly bounding the
        // hit area to the tile's layout rectangle prevents the
        // overlap.
        .contentShape(Rectangle())
    }

    private var tile: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
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
