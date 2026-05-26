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

    /// Update the current panel with new content without closing/reopening.
    /// Used when the selection changes while previewing.
    func refresh(paths: [String]) {
        let dir = ensureStagingDir()

        var staged: [PreviewItem] = []
        for path in paths {
            let source = URL(fileURLWithPath: path)
            let ext = getExtension(for: source)
            let filename = source.lastPathComponent
            let dest = dir.appendingPathComponent("\(filename)\(ext.isEmpty ? "" : ".")\(ext)")
            
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.linkItem(at: source, to: dest)
            }
            staged.append(PreviewItem(url: dest, title: filename))
        }

        self.items = staged
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func refresh(items requested: [StashItem]) {
        let dir = ensureStagingDir()

        var staged: [PreviewItem] = []
        for item in requested {
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

        self.items = staged
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    private func ensureStagingDir() -> URL {
        if let existing = stagingDir { return existing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-ql-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDir = dir
        return dir
    }

    func togglePaths(paths: [String]) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPaths(paths: paths)
        }
    }

    func toggleItems(items requested: [StashItem]) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(items: requested)
        }
    }

    /// Show the panel previewing raw file paths.
    func showPaths(paths: [String]) {
        cleanup()
        refresh(paths: paths)
        
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Show the panel previewing the given items.
    func show(items requested: [StashItem]) {
        cleanup()
        refresh(items: requested)

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
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
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
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
        let content = item.type == .email
            ? bodyOnlyMarkdown(text, title: item.title)
            : text
        let dest = dir.appendingPathComponent("\(item.id).md")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            try content.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        } catch {
            return nil
        }
    }

    private func bodyOnlyMarkdown(_ raw: String, title: String) -> String {
        let parts = raw.components(separatedBy: "\n\n")
        let body = parts.count > 1
            ? parts.dropFirst().joined(separator: "\n\n")
            : raw
        return "# \(title)\n\n\(body)"
    }

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

    private func getExtension(for url: URL) -> String {
        var ext = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredFilenameExtension) ?? ""
        if ext.isEmpty {
            if let type = sniffType(at: url) {
                ext = type.preferredFilenameExtension ?? ""
            }
        }
        return ext
    }

    private func sniffType(at url: URL) -> UTType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if data.count >= 12, data.subdata(in: 4..<12) == Data([0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]) { return .heic }
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if data.count >= 8, data.subdata(in: 4..<8) == Data([0x66, 0x74, 0x79, 0x70]) { return .mpeg4Movie }
        
        if let s = String(data: data, encoding: .utf8)?.lowercased() {
            let headers = ["return-path:", "received:", "from:", "delivered-to:", "content-type:", "message-id:"]
            if headers.contains(where: { s.contains($0) }) { return .emailMessage }
            if !data.contains(where: { $0 < 32 && ![9, 10, 13].contains($0) }) { return .plainText }
        }
        
        return nil
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

private final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}
