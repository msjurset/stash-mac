import AppKit
import AVFoundation
import CoreMedia
import Foundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Generates and persists per-item thumbnails. Source-of-bitmap
/// branches by item type and mime; output goes through
/// `ImageProcessor` and is written via the `stash thumbnail` CLI so
/// the column round-trips through the canonical store.
///
/// URL-item HTML extraction (og:image, twitter:image, …) is Phase 2
/// and lives in a separate code path. This service handles file /
/// image / audio / video sources only.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private let cli = StashCLI.shared

    enum SourceError: Error {
        case unsupportedItem
        case noContent
        case decodeFailed
        case fetchFailed(Int)
    }

    /// Auto-generate a thumbnail for the item from its existing
    /// content. Returns the relative path stored on the item.
    /// Throws `noContent` when the item type is incompatible with
    /// auto-generation (e.g. URL items, snippets) or when the
    /// underlying generator (QuickLook, AVAsset) refuses — common
    /// for archives, which macOS can't preview.
    @discardableResult
    func generate(for item: StashItem) async throws -> String {
        guard let bitmap = await sourceImage(for: item) else {
            throw SourceError.noContent
        }
        guard let data = ImageProcessor.makeThumbnailData(from: bitmap) else {
            throw SourceError.decodeFailed
        }
        return try await persist(data: data, for: item.id)
    }

    /// Set the thumbnail from a user-supplied local file. The file is
    /// decoded, post-processed, and persisted. The original file is
    /// not moved.
    @discardableResult
    func setFromFile(_ url: URL, for itemID: String) async throws -> String {
        let raw = try Data(contentsOf: url)
        guard let data = ImageProcessor.makeThumbnailData(from: raw) else {
            throw SourceError.decodeFailed
        }
        return try await persist(data: data, for: itemID)
    }

    /// Set the thumbnail from a remote image URL.
    @discardableResult
    func setFromImageURL(_ url: URL, for itemID: String) async throws -> String {
        let (raw, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SourceError.fetchFailed(http.statusCode)
        }
        guard let data = ImageProcessor.makeThumbnailData(from: raw) else {
            throw SourceError.decodeFailed
        }
        return try await persist(data: data, for: itemID)
    }

    /// Download a URL whose response is neither HTML nor an image
    /// (PDF, video, audio, Office doc, …) to a temp file with the
    /// right extension and run QuickLook on it. Used by the import
    /// path when the target URL points directly at a document file —
    /// the CLI's HTML/image branches can't render those, but QL can.
    @discardableResult
    func importViaQuickLook(_ url: URL, for itemID: String) async throws -> String {
        let (raw, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SourceError.fetchFailed(http.statusCode)
        }
        let mime = (response as? HTTPURLResponse)?.mimeType ?? ""

        // Determine extension from MIME first, then fall back to the
        // URL path's existing extension. QuickLook dispatches by
        // extension; without one it punts to a generic icon.
        var ext = ""
        if !mime.isEmpty,
           let utType = UTType(mimeType: mime),
           let mappedExt = utType.preferredFilenameExtension {
            ext = mappedExt
        }
        if ext.isEmpty {
            let pathExt = url.pathExtension
            if !pathExt.isEmpty { ext = pathExt }
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "stash-import-\(UUID().uuidString)\(ext.isEmpty ? "" : ".")\(ext)"
            )
        try raw.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        guard let bitmap = await quickLookThumbnail(at: tempFile) else {
            throw SourceError.decodeFailed
        }
        guard let data = ImageProcessor.makeThumbnailData(from: bitmap) else {
            throw SourceError.decodeFailed
        }
        return try await persist(data: data, for: itemID)
    }

    /// Render the URL in an off-screen WKWebView, snapshot the
    /// rendered viewport, and persist as the item's thumbnail. Used
    /// by the import path when the CLI's static-HTML scrape returned
    /// no candidates and QuickLook on the raw HTML wouldn't execute
    /// the JS the page relies on. WKWebView runs the same engine
    /// Safari uses, so the snapshot reflects what the user actually
    /// sees in a browser.
    @discardableResult
    func importViaWebKit(_ url: URL, for itemID: String) async throws -> String {
        let image = try await WebThumbnailRenderer.shared.render(url: url)
        guard let data = ImageProcessor.makeThumbnailData(from: image) else {
            throw SourceError.decodeFailed
        }
        return try await persist(data: data, for: itemID)
    }

    func clear(itemID: String) async throws {
        try await cli.thumbnailClear(id: itemID)
    }

    // MARK: - Source-of-bitmap

    private func sourceImage(for item: StashItem) async -> NSImage? {
        switch item.type {
        case .image:
            guard let storePath = item.storePath,
                  let url = FilePathResolver.resolve(storePath: storePath) else { return nil }
            // Critical: load through ThumbnailCache.loadOriented so
            // the EXIF rotation tag is applied BEFORE we save the
            // generated thumbnail to disk. Otherwise we bake the
            // sideways pixels into the thumbnail file and every
            // downstream consumer sees the rotated image — even if
            // they load through CGImageSource, because the saved
            // thumbnail no longer carries an orientation tag.
            return ThumbnailCache.loadOriented(from: url)
                ?? PlaceholderGenerator.generatePlaceholder(for: item)

        case .file:
            guard let storePath = item.storePath,
                  let url = FilePathResolver.resolve(storePath: storePath) else { return nil }

            // Archives get the directory-listing tree rendered as
            // their thumbnail (QuickLook has no preview generator
            // for tar/gz/zip — it would just return nil otherwise).
            if let mime = item.mimeType, isArchiveMIME(mime) {
                if let img = await archiveTreeImage(at: url, mimeType: mime) {
                    return img
                }
                // Fall through to QL on archive parse failure — at
                // worst we get a nil thumbnail and the placeholder.
            }

            // Stage the blob with a real extension so QuickLook /
            // AVFoundation can dispatch their type-specific
            // generators. Without this, a hash-named file like
            // `~/.stash/files/4f/4f8b…` is opaque to the OS and
            // QuickLook falls back to a generic file icon.
            let staged = stageURL(for: url, mimeType: item.mimeType, sourcePath: item.sourcePath)
            defer { cleanupStaged(staged, original: url) }
            let target = staged ?? url

            if let mime = item.mimeType {
                if mime.hasPrefix("video/") {
                    if let frame = await videoFrame(at: target) {
                        return frame
                    }
                }
                if mime.hasPrefix("audio/") {
                    if let artwork = await audioArtwork(at: target) {
                        return artwork
                    }
                    if let waveform = await WaveformGenerator.generateWaveform(at: target) {
                        return waveform
                    }
                }
            }
            
            if let ql = await quickLookThumbnail(at: target) {
                return ql
            }
            
            return PlaceholderGenerator.generatePlaceholder(for: item)

        case .url, .snippet, .email:
            return nil
        }
    }

    /// QuickLook handles PDFs, images, video, code, Office/iWork,
    /// archives — same engine Finder uses, so output matches the
    /// user's expectations elsewhere. Caller is responsible for
    /// staging the file with a meaningful extension first.
    private func quickLookThumbnail(at url: URL) async -> NSImage? {
        // Request `.thumbnail` (not `.all`) so QL only returns a
        // real content preview. If it can't generate one, we get
        // nil and the caller can decide what to fall back to —
        // better than silently returning the generic file icon.
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 1024, height: 1024),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }

    /// Stage the content-addressable blob in the temp dir under a
    /// filename with the correct extension. Returns the staged URL,
    /// or nil when no extension can be inferred (caller falls back
    /// to the original URL).
    ///
    /// Resolution order for the extension:
    ///  1. The original `sourcePath` (e.g. `report.pdf`) — most
    ///     accurate; preserves the exact type the user captured.
    ///  2. UTType lookup from the recorded MIME type.
    ///
    /// Uses a **hard link** rather than a symlink because QuickLook
    /// (verified empirically against `qlmanage`) refuses to generate
    /// thumbnails for symlinks — only hard-linked / real files get
    /// dispatched to type-specific generators. Falls back to a copy
    /// if hard-linking fails (e.g. cross-volume staging).
    private func stageURL(for url: URL, mimeType: String?, sourcePath: String?) -> URL? {
        var ext = ""
        if let sp = sourcePath, !sp.isEmpty {
            ext = (sp as NSString).pathExtension
        }
        if ext.isEmpty, let mime = mimeType, !mime.isEmpty,
           let utType = UTType(mimeType: mime),
           let mappedExt = utType.preferredFilenameExtension {
            ext = mappedExt
        }
        if ext.isEmpty { return nil }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-ql-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.linkItem(at: url, to: staged)
            return staged
        } catch {
            // Cross-volume hard-link, missing source, or other I/O
            // problem. Try a copy — slower but guaranteed to give QL
            // a real file with the correct extension.
            do {
                try FileManager.default.copyItem(at: url, to: staged)
                return staged
            } catch {
                return nil
            }
        }
    }

    private func cleanupStaged(_ staged: URL?, original: URL) {
        guard let staged, staged != original else { return }
        try? FileManager.default.removeItem(at: staged)
    }

    /// Render the archive's directory tree to a 512pt NSImage via
    /// `ImageRenderer`. Archive parsing happens on a background
    /// task; the SwiftUI render is hopped back to the main actor.
    /// Returns nil if the archive is empty or unreadable, letting
    /// the caller fall through to other paths.
    private func archiveTreeImage(at url: URL, mimeType: String) async -> NSImage? {
        let entries: [ArchiveEntry]? = await Task.detached(priority: .userInitiated) {
            try? listArchive(url: url, mimeType: mimeType)
        }.value
        guard let entries, !entries.isEmpty else { return nil }
        let tree = buildTree(from: entries)

        let view = ArchiveThumbnailView(tree: tree)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage
    }

    /// Pick a video frame at 10% in (skipping black intro frames) and
    /// hand back as NSImage for downstream resize/encode.
    private func videoFrame(at url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1024, height: 1024)

        let target: CMTime
        if let dur = try? await asset.load(.duration), dur.seconds > 1 {
            target = CMTimeMultiplyByFloat64(dur, multiplier: 0.1)
        } else {
            target = .zero
        }

        do {
            let result = try await gen.image(at: target)
            return NSImage(cgImage: result.image, size: .zero)
        } catch {
            return nil
        }
    }

    /// Common-metadata artwork for audio (ID3 cover art etc.). Returns
    /// nil when the file has no embedded artwork — the caller decides
    /// whether to fall back to a type-badge tile or leave the item
    /// without a thumbnail.
    private func audioArtwork(at url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        do {
            let items = try await asset.load(.commonMetadata)
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try await item.load(.dataValue),
                   let img = NSImage(data: data) {
                    return img
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Persistence

    /// Write the JPEG bytes to a temp file and hand off to the CLI.
    /// The CLI moves the file into the filestore and updates the
    /// column atomically; we delete the temp on the way out.
    private func persist(data: Data, for itemID: String) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-thumb-\(UUID().uuidString).jpg")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await cli.thumbnailSet(id: itemID, file: tmp.path)
    }
}
