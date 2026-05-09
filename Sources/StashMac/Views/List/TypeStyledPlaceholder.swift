import SwiftUI

/// Type-styled fallback for items without a real thumbnail. Each
/// type gets its own gradient + iconography so a thumbnail-less grid
/// still looks intentional rather than a wall of generic SF symbols.
///
/// Used by `ItemTile` (uniform grid) and `MasonryTile` (collection
/// masonry) when `thumbnailPath` is nil or the file is missing.
struct TypeStyledPlaceholder: View {
    let item: StashItem

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.top, palette.bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
                .padding(10)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .url:
            urlContent
        case .file:
            fileContent
        case .image:
            singleIcon("photo")
        case .snippet:
            snippetContent
        case .email:
            emailContent
        }
    }

    // MARK: - Per-type content

    private var urlContent: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "globe")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.85))
            if let host = urlHost(item.url) {
                Text(host)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var fileContent: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(fileExtensionBadge(item))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if let size = item.humanFileSize {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
    }

    private var snippetContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "text.alignleft")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            Text(snippetPreview(item))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private var emailContent: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "envelope")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.85))
            if let sender = item.fromName {
                Text(sender)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func singleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 36))
            .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: - Palette

    private struct Palette {
        let top: Color
        let bottom: Color
    }

    private var palette: Palette {
        switch item.type {
        case .url:
            return Palette(top: Color(red: 0.20, green: 0.40, blue: 0.85),
                           bottom: Color(red: 0.10, green: 0.20, blue: 0.55))
        case .file:
            return Palette(top: Color(red: 0.35, green: 0.40, blue: 0.50),
                           bottom: Color(red: 0.18, green: 0.22, blue: 0.32))
        case .image:
            return Palette(top: Color(red: 0.85, green: 0.40, blue: 0.65),
                           bottom: Color(red: 0.45, green: 0.20, blue: 0.55))
        case .snippet:
            return Palette(top: Color(red: 0.85, green: 0.65, blue: 0.20),
                           bottom: Color(red: 0.55, green: 0.40, blue: 0.10))
        case .email:
            return Palette(top: Color(red: 0.45, green: 0.40, blue: 0.85),
                           bottom: Color(red: 0.25, green: 0.20, blue: 0.55))
        }
    }

    // MARK: - Field helpers

    private func urlHost(_ urlString: String?) -> String? {
        guard let s = urlString, let url = URL(string: s),
              let host = url.host else { return nil }
        // Strip leading "www." for visual cleanliness — every "www."
        // prefix is the same noise across most rows.
        if host.hasPrefix("www.") { return String(host.dropFirst(4)) }
        return host
    }

    /// File extension shown as a chunky monospaced label. Resolves
    /// from `sourcePath` first (most accurate), then the title (often
    /// includes the original filename), then mimeType-derived. Caps
    /// at 5 chars so weird long mimes don't blow out the layout.
    private func fileExtensionBadge(_ item: StashItem) -> String {
        if let sp = item.sourcePath, !sp.isEmpty {
            let ext = (sp as NSString).pathExtension
            if !ext.isEmpty { return formatBadge(ext) }
        }
        let titleExt = (item.title as NSString).pathExtension
        if !titleExt.isEmpty { return formatBadge(titleExt) }
        if let mime = item.mimeType {
            if let slash = mime.firstIndex(of: "/") {
                let sub = String(mime[mime.index(after: slash)...])
                let trimmed = sub.split(separator: ";").first.map(String.init) ?? sub
                return formatBadge(trimmed)
            }
        }
        return "FILE"
    }

    private func formatBadge(_ raw: String) -> String {
        let s = raw.uppercased()
        if s.count > 5 { return String(s.prefix(5)) }
        return s
    }

    private func snippetPreview(_ item: StashItem) -> String {
        let text = item.extractedText ?? item.notes ?? item.title
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return item.title }
        if trimmed.count > 240 {
            return String(trimmed.prefix(240)) + "…"
        }
        return trimmed
    }
}
