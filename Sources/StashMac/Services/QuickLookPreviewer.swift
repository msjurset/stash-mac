import AppKit
import Foundation
import Quartz
import UniformTypeIdentifiers

/// Drives `QLPreviewPanel` for spacebar-style previews. Stash blobs
/// live in the filestore as hash-named files with no extension, so
/// QL can't dispatch generators directly. We stage each previewed
/// item as a hardlink (or copy fallback) under a real filename in a
/// dedicated temp dir, hand those staged URLs to the panel, and
/// clean up when the panel dismisses.
@MainActor
final class QuickLookPreviewer: NSObject {
    static let shared = QuickLookPreviewer()

    private var items: [PreviewItem] = []
    private var stagingDir: URL?

    /// Show the panel previewing the given items. Two staging paths:
    ///   - Items with a stored blob (file/image) → hardlink (or
    ///     copy) into the staging dir under a real extension so QL
    ///     dispatches its type-specific generators.
    ///   - Items with only `extractedText` (snippet/email) → write
    ///     the text to a `.md` file (the extractor already produces
    ///     markdown-formatted content) so QL renders it as text.
    /// URL items with neither are silently skipped.
    func show(items requested: [StashItem]) {
        cleanup()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-ql-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDir = dir

        var staged: [PreviewItem] = []
        for item in requested {
            // Email items have a stored `.eml` blob, but QL's email
            // renderer refuses to display the body inline regardless
            // of MIME shape — confirmed empirically across `.txt`,
            // `.md`, and `.eml` extensions. Skip stageBlob for them
            // and use the text path, which strips headers and
            // renders the body as markdown.
            if item.type == .email {
                if let dest = stageText(for: item, in: dir) {
                    staged.append(PreviewItem(url: dest, title: item.title))
                }
                continue
            }
            if let dest = stageBlob(for: item, in: dir) {
                staged.append(PreviewItem(url: dest, title: item.title))
                continue
            }
            if let dest = stageText(for: item, in: dir) {
                staged.append(PreviewItem(url: dest, title: item.title))
                continue
            }
        }

        guard !staged.isEmpty else { return }
        items = staged

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func stageBlob(for item: StashItem, in dir: URL) -> URL? {
        guard let storePath = item.storePath,
              let source = FilePathResolver.resolve(storePath: storePath) else {
            return nil
        }
        let ext = inferredExtension(for: item)
        let dest = dir.appendingPathComponent(
            "\(item.id)\(ext.isEmpty ? "" : ".")\(ext)"
        )
        do {
            try FileManager.default.linkItem(at: source, to: dest)
            return dest
        } catch {
            if (try? FileManager.default.copyItem(at: source, to: dest)) != nil {
                return dest
            }
        }
        return nil
    }

    private func stageText(for item: StashItem, in dir: URL) -> URL? {
        guard let text = item.extractedText, !text.isEmpty else { return nil }
        // Emails: macOS's Mail QL plugin recognizes any RFC 822
        // shape (incl. proper `.eml` with full MIME headers) and
        // routes to the email renderer — but that renderer fails
        // to display the body inline regardless of how the message
        // is formatted. Confirmed empirically: `.txt`, `.md`, and
        // `.eml` all hit the same dead end. Workaround is to strip
        // the header block and lead with `# {title}` so QL stays
        // on the markdown renderer. Headers remain visible in the
        // detail view (right pane), so nothing is hidden — the QL
        // preview just shows the message body, which is the part
        // you actually want when scanning.
        let content = item.type == .email
            ? bodyOnlyMarkdown(text, title: item.title)
            : text
        let dest = dir.appendingPathComponent("\(item.id).md")
        do {
            try content.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        } catch {
            return nil
        }
    }

    /// Drop the From/To/Subject/Date header block from extractedText
    /// (RFC 822 boundary = first blank line) and lead with the
    /// item's title as a markdown H1.
    private func bodyOnlyMarkdown(_ raw: String, title: String) -> String {
        let parts = raw.components(separatedBy: "\n\n")
        let body = parts.count > 1
            ? parts.dropFirst().joined(separator: "\n\n")
            : raw
        return "# \(title)\n\n\(body)"
    }

    /// Clear staged files. Called automatically when the panel
    /// closes; safe to call eagerly when starting a new preview.
    private func cleanup() {
        items = []
        if let dir = stagingDir {
            try? FileManager.default.removeItem(at: dir)
            stagingDir = nil
        }
    }

    private func inferredExtension(for item: StashItem) -> String {
        if let sp = item.sourcePath, !sp.isEmpty {
            let ext = (sp as NSString).pathExtension
            if !ext.isEmpty { return ext }
        }
        if let mime = item.mimeType, !mime.isEmpty,
           let utType = UTType(mimeType: mime),
           let mappedExt = utType.preferredFilenameExtension {
            return mappedExt
        }
        return ""
    }
}

extension QuickLookPreviewer: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items[index]
    }
}

extension QuickLookPreviewer: @preconcurrency QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}

/// `QLPreviewItem` is `@objc` so we have to bridge through NSObject.
/// `previewItemTitle` lets us show the stash item's user-facing
/// title in the panel chrome instead of the staged temp filename.
private final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}
