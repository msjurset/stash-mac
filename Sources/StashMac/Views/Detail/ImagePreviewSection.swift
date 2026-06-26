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
                    .contextMenu {
                        Button("Set as Desktop Background") {
                            for screen in NSScreen.screens {
                                try? NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
                            }
                        }
                    }
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
            do {
                // Debounce selection: wait 100ms before loading full image.
                try await Task.sleep(nanoseconds: 100 * 1_000_000)
                await load()
            } catch {
                // Task was cancelled, do nothing
            }
        }
    }

    private func load() async {
        let url = fileURL
        // Use the shared ThumbnailCache so it benefits from memory caching and pre-warming.
        let img = await ThumbnailCache.shared.loadAsync(path: url.path)
        
        // Guard against the file URL having changed (user navigated)
        // mid-decode.
        guard fileURL == url else { return }
        if img != nil { image = img }
    }
}
