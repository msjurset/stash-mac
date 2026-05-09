import AppKit
import SwiftUI

/// Renders a thumbnail at a relative store path. On cache hit the
/// image shows synchronously on first render; on cache miss the
/// fallback view shows while the decode runs off-thread, then the
/// image swaps in.
///
/// All callers in the list / grid / detail surfaces should use this
/// instead of `NSImage(contentsOf:)` inline — the inline pattern
/// stalls the main thread on every navigation click and the runloop
/// lag manifests as sidebars and toolbars reading as "disabled".
struct AsyncThumbnailImage<Fallback: View>: View {
    /// Relative path stored on the item (e.g. `thumbnailPath`).
    let relativePath: String?
    /// What to render until the image is ready (or when no thumbnail
    /// exists). Typed-styled placeholders, type icons, etc.
    let fallback: () -> Fallback
    /// Modifier applied to the resolved Image — typical pattern is
    /// `.resizable().aspectRatio(contentMode: .fill)` etc.
    let configure: (Image) -> AnyView

    init(
        relativePath: String?,
        @ViewBuilder fallback: @escaping () -> Fallback,
        configure: @escaping (Image) -> AnyView = { AnyView($0.resizable().aspectRatio(contentMode: .fill)) }
    ) {
        self.relativePath = relativePath
        self.fallback = fallback
        self.configure = configure
    }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                configure(Image(nsImage: image))
            } else {
                fallback()
            }
        }
        .task(id: relativePath ?? "") {
            await load()
        }
    }

    private func load() async {
        guard let rel = relativePath,
              let url = FilePathResolver.resolveRelative(rel) else {
            image = nil
            return
        }
        let path = url.path
        if let cached = ThumbnailCache.shared.image(forPath: path) {
            image = cached
            return
        }
        // Reset to fallback while decoding so a quick switch from
        // an item with a thumbnail to one without doesn't hold the
        // previous image on screen during the decode window.
        image = nil
        let loaded = await ThumbnailCache.shared.loadAsync(path: path)
        image = loaded
    }
}
