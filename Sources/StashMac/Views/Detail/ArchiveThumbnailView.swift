import SwiftUI

/// Compact rendering of an archive's directory tree for use as the
/// item's thumbnail. Always-expanded, monospaced rows, capped at a
/// modest entry count so the 512pt canonical thumbnail stays
/// readable when shrunk to list-row size.
///
/// Produced offscreen via `ImageRenderer` from `ThumbnailService`;
/// not added to the detail view directly (`ArchiveContentsView`
/// already handles the interactive tree there).
struct ArchiveThumbnailView: View {
    let tree: ArchiveNode

    /// Cap so a 200-file tarball doesn't render an unreadable 8pt
    /// font column. The "+ N more" footer surfaces the rest.
    private static let maxRows = 22

    /// Fixed 512×512 canvas — the canonical thumbnail edge.
    /// Row height + font size are derived from the entry count so
    /// the listing always fills the square, whether the archive has
    /// 4 entries or 22.
    private static let canvas: CGFloat = 512
    private static let padding: CGFloat = 28

    var body: some View {
        let entries = flatten(tree, depth: 0)
        let visible = Array(entries.prefix(Self.maxRows))
        let overflow = entries.count - visible.count
        let displayCount = max(visible.count + (overflow > 0 ? 1 : 0), 1)
        let rowHeight = (Self.canvas - 2 * Self.padding) / CGFloat(displayCount)
        let fontSize = rowHeight * 0.62
        let iconSize = rowHeight * 0.7

        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { entry in
                row(for: entry, rowHeight: rowHeight, fontSize: fontSize, iconSize: iconSize)
            }
            if overflow > 0 {
                HStack {
                    Text("+ \(overflow) more")
                        .font(.system(size: fontSize * 0.85, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(height: rowHeight)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.canvas, height: Self.canvas, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func row(
        for entry: FlatEntry,
        rowHeight: CGFloat,
        fontSize: CGFloat,
        iconSize: CGFloat
    ) -> some View {
        HStack(spacing: rowHeight * 0.25) {
            if entry.depth > 0 {
                Spacer().frame(width: CGFloat(entry.depth) * rowHeight * 0.9)
            }
            Image(systemName: entry.node.isDir ? "folder.fill" : "doc")
                .font(.system(size: iconSize))
                .foregroundStyle(entry.node.isDir ? .orange : .secondary)
                .frame(width: iconSize * 1.3)
            Text(entry.node.name)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
    }
}

private struct FlatEntry: Identifiable {
    let id: UUID
    let node: ArchiveNode
    let depth: Int
}

/// Walk the tree breadth/depth-first; root with empty `name` is
/// elided so a single-archive listing doesn't waste a row on a
/// blank folder line.
private func flatten(_ node: ArchiveNode, depth: Int) -> [FlatEntry] {
    var out: [FlatEntry] = []
    if !node.name.isEmpty {
        out.append(FlatEntry(id: node.id, node: node, depth: depth))
    }
    let nextDepth = node.name.isEmpty ? depth : depth + 1
    for child in node.sortedChildren {
        out += flatten(child, depth: nextDepth)
    }
    return out
}
