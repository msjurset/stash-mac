import AppKit
import SwiftUI

/// Full-resolution image preview for image-type items. Decodes the
/// file off the main thread so navigating to a large image (e.g. a
/// multi-megabyte photo) doesn't stall the runloop on
/// NSImage(contentsOf:) inside the detail view's body.
///
/// Distinct from `AsyncThumbnailImage` because this loads the full
/// file rather than the cached thumbnail, and routes the loaded
/// image into `ImagePreviewPresenter` on tap so the user can pop a
/// full-screen viewer.
struct ImagePreviewSection: View {
    let fileURL: URL
    var allURLs: [URL] = []
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 500, maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        let urls = allURLs.isEmpty ? [fileURL] : allURLs
                        let index = urls.firstIndex(of: fileURL) ?? 0
                        ImagePreviewPresenter.present(urls: urls, initialIndex: index)
                    }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help("Click to open in viewer")
            } else {
                // Skeleton-ish placeholder while the decode runs.
                // Same maxWidth/maxHeight as the loaded image so the
                // layout doesn't jump when the image swaps in.
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(maxWidth: 500, maxHeight: 400)
                    .overlay(
                        ProgressView().controlSize(.small)
                    )
            }
        }
        // Crossfade swaps between images / placeholder rather than
        // hard-cutting — keeps the multi-file carousel feel smooth
        // when the user taps from one strip thumbnail to another.
        .animation(.easeInOut(duration: 0.18), value: image)
        .task(id: fileURL.path) {
            await load()
        }
    }

    private func load() async {
        let url = fileURL
        // Keep the previous image visible while decoding the next
        // one — clearing it produced a "whole page refresh" flash
        // when tapping carousel strip thumbnails. The detached
        // decode is fast for any already-on-disk file and the new
        // image swaps in via the .animation crossfade above.
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            // ThumbnailCache.loadOriented honors EXIF rotation —
            // bare NSImage(contentsOf:) leaves portrait-shot photos
            // rendering on their side. The cache version reads
            // through CGImageSource at up to 1024px on the long
            // edge, which is more than enough for the detail
            // preview at this view size and saves multi-MP decodes.
            return ThumbnailCache.loadOriented(from: url)
        }.value
        // Guard against the file URL having changed (user navigated)
        // mid-decode. SwiftUI cancels the .task on id change, but
        // detached children still finish.
        guard fileURL == url else { return }
        // Only update if we actually got a new image — leaves the
        // previous image up if the next file is unreadable rather
        // than blanking the view.
        if img != nil { image = img }
    }
}
