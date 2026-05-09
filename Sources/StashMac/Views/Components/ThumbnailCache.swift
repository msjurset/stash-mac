import AppKit
import Foundation

/// Process-global cache of decoded thumbnail NSImages keyed by their
/// resolved file path. Backed by NSCache so it auto-evicts under
/// memory pressure. Without this, every navigation through the items
/// list re-decoded the same thumbnails on the main thread, which
/// stalled the runloop long enough for the sidebar to read as
/// disabled.
///
/// Aspect ratio is cached separately because the masonry grid needs
/// it to lay out cells *before* any view is rendered — and we don't
/// want to force the whole NSImage decode into that path.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let images = NSCache<NSString, NSImage>()
    private var aspects: [String: CGFloat] = [:]
    private var inflightLoads: Set<String> = []

    private init() {
        // Modest cap — thumbnails at this size run ~100–500 KB
        // decoded; 200 entries is a few hundred MB worst case but
        // typical libraries are well under that and NSCache evicts
        // under pressure anyway.
        images.countLimit = 200
    }

    /// Synchronous lookup — returns a cached image immediately or
    /// nil on miss. Callers should pair this with `loadAsync` so a
    /// miss kicks off a background decode.
    func image(forPath path: String) -> NSImage? {
        images.object(forKey: path as NSString)
    }

    /// Cached aspect ratio (width / height), clamped to [0.4, 2.5]
    /// to mirror the masonry grid's layout cap. Returns nil on miss
    /// — caller decides what to do (typically: render with 1.0
    /// while loadAsync populates the cache, then re-render on the
    /// resulting state change).
    func aspect(forPath path: String) -> CGFloat? {
        aspects[path]
    }

    /// Decode the image off the main thread, populate both caches,
    /// and return the loaded image. Subsequent callers for the same
    /// path are dedup'd via the inflight set so a list of 100
    /// identical thumbnails doesn't spawn 100 decode tasks.
    @discardableResult
    func loadAsync(path: String) async -> NSImage? {
        if let cached = images.object(forKey: path as NSString) {
            return cached
        }
        if inflightLoads.contains(path) {
            // Another caller is already decoding. Wait briefly and
            // return whatever ends up cached. Crude but good enough
            // for the navigation use case — the duplicates are rare
            // and the wait is bounded by the actual decode time.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if let cached = images.object(forKey: path as NSString) {
                    return cached
                }
                if !inflightLoads.contains(path) { break }
            }
            return images.object(forKey: path as NSString)
        }
        inflightLoads.insert(path)
        defer { inflightLoads.remove(path) }

        let url = URL(fileURLWithPath: path)
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSImage(contentsOf: url)
        }.value

        guard let img else { return nil }
        images.setObject(img, forKey: path as NSString)
        let size = img.size
        if size.width > 0, size.height > 0 {
            let raw = size.width / size.height
            aspects[path] = max(0.4, min(raw, 2.5))
        }
        return img
    }

    /// Drop a cached entry — used when a thumbnail is regenerated
    /// or cleared so the next render decodes the new bytes instead
    /// of returning the stale cached image.
    func invalidate(path: String) {
        images.removeObject(forKey: path as NSString)
        aspects.removeValue(forKey: path)
    }
}
