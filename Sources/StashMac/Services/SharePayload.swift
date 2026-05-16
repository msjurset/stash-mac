import Foundation
import AppKit
import UniformTypeIdentifiers

/// Builds the `[Any]` payload that gets fed into
/// `NSSharingServicePicker`. Each item contributes its natural
/// representation: a file URL for image / file items, an
/// `https://…` URL for link items, the snippet text for snippet
/// items, the extracted email body for email items. Notes flow in
/// as a trailing text element when present so Messages / Mail /
/// Signal automatically pre-populate the message body alongside
/// the attachment.
///
/// The macOS Share Sheet handles the heterogeneous `[Any]` shape
/// transparently — each sharing service picks the elements it
/// understands and ignores the rest.
enum SharePayload {
    /// Build the payload for a single item. Returns an empty array
    /// when the item has nothing shareable (no URL, no resolvable
    /// file, no text). Callers should guard on `isEmpty` before
    /// showing the picker.
    static func build(for item: StashItem) -> [Any] {
        var payload: [Any] = []

        // File URL for image / file items. Resolved through the
        // existing FilePathResolver so the path lives under the
        // user's configured files-dir regardless of where the
        // bundle was installed.
        //
        // For image items we ALSO append an NSImage representation
        // so paste-into-a-text-field gets the actual image content
        // rather than the file URL's basename (the content hash,
        // which reads as a meaningless alphanumeric string). Apps
        // that prefer the file reference (Mail, AirDrop, Slack)
        // still get it from the URL entry — NSSharingService picks
        // its preferred type from the heterogeneous payload.
        if let storePath = item.storePath,
           let url = FilePathResolver.resolve(storePath: storePath),
           FileManager.default.fileExists(atPath: url.path) {
            // Stash files live in a content-addressable store
            // under `~/.stash/files/<hash>` with no extension —
            // pasting that raw URL into Signal / Mail / iMessage
            // attaches a file the recipient can't open. Stage a
            // sibling temp copy named `<title-slug>.<ext>` so the
            // attachment has a sensible filename + extension.
            let stagedURL = stageForShare(url: url, item: item) ?? url
            payload.append(stagedURL)
            if item.type == .image, let image = NSImage(contentsOf: stagedURL) {
                payload.append(image)
            }
        }

        // External URL for link items. The Mail / Messages / Signal
        // share services treat this as either an attachment link or
        // plain text depending on their preference.
        if let raw = item.url,
           !raw.isEmpty,
           let url = URL(string: raw) {
            payload.append(url)
        }

        // Snippet / email body text. For URL items the title is
        // included too so the recipient sees a label rather than
        // a bare URL.
        switch item.type {
        case .snippet:
            if let text = item.extractedText, !text.isEmpty {
                payload.append(text)
            } else if let caption = caption(for: item) {
                payload.append(caption)
            }
        case .email:
            if let text = item.extractedText, !text.isEmpty {
                payload.append(text)
            }
        default:
            // For URL / file / image / archive items: a single
            // combined "title + notes" caption. Apps that paste
            // text (Signal / Teams / Slack message inputs) get a
            // human-readable string rather than the file URL's
            // alphanumeric basename.
            if let caption = caption(for: item) {
                payload.append(caption)
            }
        }

        return payload
    }

    /// Copy a stash-store file (extensionless content hash) into
    /// a per-share temp directory under a human-readable filename
    /// derived from `item.title`, with the right extension for
    /// the file's actual content type. Recipients see
    /// `bull-thistle.jpg` instead of a 40-char hash.
    private static func stageForShare(url: URL, item: StashItem) -> URL? {
        let slug = titleSlug(for: item)
        let ext = preferredExtension(for: url, item: item)
        let basename = ext.isEmpty ? slug : "\(slug).\(ext)"
        // Per-share subdirectory so successive shares don't
        // collide on a title that resolves to the same slug. Also
        // gives macOS a natural boundary for temp cleanup.
        let session = ProcessInfo.processInfo.globallyUniqueString
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-share")
            .appendingPathComponent(session)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(basename)
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Title → filesystem-safe slug. Lowercase, runs of non-
    /// alphanumeric collapse to a single hyphen. Falls back to a
    /// stable "stash-item" so we always have a name.
    private static func titleSlug(for item: StashItem) -> String {
        let lower = item.title.lowercased()
        var out = ""
        var lastWasHyphen = false
        for c in lower {
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasHyphen = false
            } else if !lastWasHyphen, !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "stash-item" : out
    }

    /// Pick an extension for the staged copy. Priority:
    ///   1. macOS's content-type sniff (looks at the file header
    ///      via UTI, most accurate for our content-addressed
    ///      hash-named files which have no extension).
    ///   2. The original path's extension, when present.
    ///   3. The item's MIME type → preferred extension via UTType.
    ///   4. "bin" as a last-resort marker so it's at least typed.
    private static func preferredExtension(for url: URL, item: StashItem) -> String {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = values.contentType,
           let ext = type.preferredFilenameExtension {
            return ext
        }
        if !url.pathExtension.isEmpty {
            return url.pathExtension
        }
        if let mime = item.mimeType,
           let type = UTType(mimeType: mime),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        return "bin"
    }

    /// Combined "title + notes" string. Returns nil when both are
    /// empty so we don't append a stray empty entry to the payload.
    private static func caption(for item: StashItem) -> String? {
        let parts = [item.title, item.notes ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return nil }
        return parts.joined(separator: "\n\n")
    }

    /// Build the combined payload for a set of items. Useful when
    /// the user multi-selects in the list view and right-clicks
    /// Share. Each item contributes its own elements; the share
    /// sheet handles the heterogeneous mix.
    static func build(for items: [StashItem]) -> [Any] {
        items.flatMap { build(for: $0) }
    }
}
