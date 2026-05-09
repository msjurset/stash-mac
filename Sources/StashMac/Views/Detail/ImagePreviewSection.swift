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
                        ImagePreviewPresenter.present(image: image)
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
        .task(id: fileURL.path) {
            await load()
        }
    }

    private func load() async {
        let url = fileURL
        // Reset before kicking off a new load so a quick navigation
        // away doesn't keep the previous image on screen during the
        // decode window.
        image = nil
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSImage(contentsOf: url)
        }.value
        // Guard against the file URL having changed (user navigated)
        // mid-decode. SwiftUI cancels the .task on id change, but
        // detached children still finish.
        guard fileURL == url else { return }
        image = img
    }
}
