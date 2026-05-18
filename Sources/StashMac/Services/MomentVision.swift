import AppKit
import ImageIO
import Vision

/// On-device scene classifier for Moments suggestions. Runs Apple's
/// built-in `VNClassifyImageRequest` against each item's thumbnail
/// (or blob fallback) and aggregates the labels across a cluster
/// into a single hint surfaced on the cluster card.
///
/// Why this is useful: the existing suggested-name logic combines
/// shared tags + date range. When the cluster has no shared tag,
/// the name falls back to just the date ("2026-05-16"). The vision
/// hint fills that gap by deriving a content label from the actual
/// pixels — "flowers", "outdoor", "food", "people", etc. — without
/// requiring the user to have tagged anything.
///
/// 100% on-device. No Vision model files to ship; the classifier
/// is built into the OS.
@MainActor
enum MomentVision {

    /// Cached per-item classification results. Keyed by item ID
    /// because each item's labels are stable across clusters — an
    /// item in a re-clustered Moment doesn't need re-classifying.
    private static var perItemCache: [String: [VisionLabel]] = [:]

    struct VisionLabel: Equatable, Sendable {
        let identifier: String
        let confidence: Float
    }

    /// Aggregated cluster-level hint. `coverage` is the fraction of
    /// the cluster's items where this label landed above threshold;
    /// the card surfaces it only when coverage is high enough to
    /// trust the signal.
    struct ClusterHint: Equatable, Sendable {
        let label: String
        let coverage: Double
        let confidence: Float
    }

    /// Confidence threshold for accepting a per-item label. Apple's
    /// classifier returns hierarchical labels (light → outdoor →
    /// flower → plant) with monotonically decreasing confidences;
    /// 0.3 filters out the very-general top-of-hierarchy noise
    /// while keeping the actually-useful subject labels.
    nonisolated static let perItemThreshold: Float = 0.3

    /// Minimum cluster coverage to surface a hint. With 5+ items
    /// and 50% coverage the label is meaningful; below that, the
    /// signal's too thin to compete with the user's own tags.
    nonisolated static let coverageFloor: Double = 0.5

    /// Classify one item, caching by item.id. Image source is
    /// thumbnail-first, blob-fallback — same precedence as the
    /// Moments detail-grid render path, so we don't pay an extra
    /// decode of the full image when a thumb already exists.
    static func classify(
        item: StashCLI.MomentSuggestion.MomentItem
    ) async -> [VisionLabel] {
        if let cached = perItemCache[item.id] {
            return cached
        }
        guard let url = sourceURL(for: item) else {
            perItemCache[item.id] = []
            return []
        }
        let labels = await Task.detached(priority: .utility) {
            classifyOffMain(url: url)
        }.value
        perItemCache[item.id] = labels
        return labels
    }

    /// Aggregate across every item in the suggestion. Returns nil
    /// when no label clears the coverage floor; the card then
    /// shows just the existing tag/date name with no hint badge.
    static func enrich(
        _ suggestion: StashCLI.MomentSuggestion
    ) async -> ClusterHint? {
        guard !suggestion.items.isEmpty else { return nil }
        // Classifications run sequentially per cluster — the
        // off-main classifyOffMain is the heavy bit, and at 19
        // items × ~30 ms each it's <1 s for a cold cluster. Cache
        // hits collapse the cost to near-zero on re-views.
        // Parallelizing across items would need a Sendable
        // boundary the actor checker is currently fussy about;
        // not worth the complexity for the speedup.
        var counts: [String: (count: Int, summedConfidence: Float)] = [:]
        for item in suggestion.items {
            let labels = await classify(item: item)
            // Keep only the strongest label per image — the
            // classifier emits the whole hierarchy and counting
            // every layer biases toward generic top-level labels
            // ("light", "indoor"). The most-specific high-
            // confidence one is what we want.
            guard let top = labels.first(where: { $0.confidence >= Self.perItemThreshold }) else {
                continue
            }
            counts[top.identifier, default: (0, 0)].count += 1
            counts[top.identifier]!.summedConfidence += top.confidence
        }
        guard let (label, agg) = counts.max(by: { $0.value.summedConfidence < $1.value.summedConfidence }) else {
            return nil
        }
        let coverage = Double(agg.count) / Double(suggestion.items.count)
        guard coverage >= coverageFloor else { return nil }
        return ClusterHint(
            label: label,
            coverage: coverage,
            confidence: agg.summedConfidence / Float(agg.count)
        )
    }

    /// Clear the per-item cache. Used when the user explicitly
    /// refreshes — keeps stale data from sticking if an item's
    /// underlying image somehow changes.
    static func resetCache() {
        perItemCache.removeAll()
    }

    // MARK: - Private

    private static func sourceURL(for item: StashCLI.MomentSuggestion.MomentItem) -> URL? {
        // Prefer the cached thumbnail — small, already oriented,
        // fast to decode. Fall back to the original blob for items
        // that pre-date thumbnail generation.
        if let rel = item.thumbnailPath, !rel.isEmpty,
           let url = FilePathResolver.resolveRelative(rel),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let sp = item.storePath, !sp.isEmpty,
           let url = FilePathResolver.resolve(storePath: sp) {
            return url
        }
        return nil
    }

    /// Off-main classification body. Loads the image via
    /// CGImageSource (oriented), wraps in a VNImageRequestHandler,
    /// runs `VNClassifyImageRequest`, and returns the labels above
    /// our floor in confidence order. Errors collapse to an empty
    /// label list — a single failed classify shouldn't poison the
    /// cluster aggregation.
    nonisolated private static func classifyOffMain(url: URL) -> [VisionLabel] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return []
        }
        // Decode at modest size — the classifier doesn't benefit
        // from full-res input, and a 512px thumbnail is plenty.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return []
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNClassifyImageRequest()
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        return observations
            .filter { $0.confidence >= perItemThreshold }
            .sorted { $0.confidence > $1.confidence }
            .map { VisionLabel(identifier: $0.identifier, confidence: $0.confidence) }
    }
}
