import SwiftUI
import Foundation

struct ArchiveContentsView: View {
    let fileURL: URL
    let mimeType: String
    @State private var tree: ArchiveNode?
    @State private var loadError: String?

    var body: some View {
        DetailSection(title: "Archive Contents") {
            if let tree {
                VStack(alignment: .leading, spacing: 0) {
                    if tree.name.isEmpty {
                        ForEach(tree.sortedChildren) { child in
                            ArchiveNodeRow(node: child, depth: 0)
                        }
                    } else {
                        ArchiveNodeRow(node: tree, depth: 0)
                    }
                }
                .font(.system(.callout, design: .monospaced))
            } else if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task {
            loadTree()
        }
    }

    private func loadTree() {
        do {
            let entries = try listArchive(url: fileURL, mimeType: mimeType)
            tree = buildTree(from: entries)
        } catch {
            loadError = "Could not read archive: \(error.localizedDescription)"
        }
    }
}

// MARK: - Archive reading

private struct ArchiveEntry {
    let name: String
    let size: Int64
    let isDir: Bool
}

private func listArchive(url: URL, mimeType: String) throws -> [ArchiveEntry] {
    if mimeType.contains("gzip") || mimeType.contains("tar") {
        return try listTarGz(url: url)
    }
    if mimeType.contains("zip") {
        return try listZip(url: url)
    }
    return []
}

private func listTarGz(url: URL) throws -> [ArchiveEntry] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }

    let data = handle.readDataToEndOfFile()
    let decompressed = try decompressGzip(data)

    var entries: [ArchiveEntry] = []
    var offset = 0

    while offset + 512 <= decompressed.count {
        let header = decompressed[offset..<offset + 512]

        // Check for end-of-archive (two zero blocks)
        if header.allSatisfy({ $0 == 0 }) { break }

        let name = extractTarString(header, range: 0..<100)
        let sizeStr = extractTarString(header, range: 124..<136)
        let typeFlag = header[header.startIndex + 156]

        // Parse prefix (POSIX ustar)
        let prefix = extractTarString(header, range: 345..<500)
        let fullName: String
        if !prefix.isEmpty {
            fullName = prefix + "/" + name
        } else {
            fullName = name
        }

        let size = Int64(sizeStr, radix: 8) ?? 0
        let isDir = typeFlag == 0x35 /* '5' */ || fullName.hasSuffix("/")

        entries.append(ArchiveEntry(name: fullName, size: size, isDir: isDir))

        // Advance past header + data blocks (rounded up to 512)
        let dataBlocks = (Int(size) + 511) / 512
        offset += 512 + dataBlocks * 512
    }

    return entries
}

private func extractTarString(_ data: Data, range: Range<Int>) -> String {
    let start = data.startIndex + range.lowerBound
    let end = data.startIndex + range.upperBound
    guard start < data.endIndex else { return "" }
    let slice = data[start..<min(end, data.endIndex)]
    // Trim null bytes
    if let nullIndex = slice.firstIndex(of: 0) {
        return String(data: slice[slice.startIndex..<nullIndex], encoding: .utf8) ?? ""
    }
    return String(data: slice, encoding: .utf8) ?? ""
}

private func decompressGzip(_ data: Data) throws -> Data {
    // Use Process with gzip -d for decompression
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    process.arguments = ["-c"]

    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    try process.run()
    stdin.fileHandleForWriting.write(data)
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    return stdout.fileHandleForReading.readDataToEndOfFile()
}

private func listZip(url: URL) throws -> [ArchiveEntry] {
    // Use Process with zipinfo for listing
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    process.arguments = ["-1", url.path]

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    return output.split(separator: "\n").map { line in
        let name = String(line)
        return ArchiveEntry(name: name, size: 0, isDir: name.hasSuffix("/"))
    }
}

// MARK: - Tree model

struct ArchiveNode: Identifiable {
    let id = UUID()
    let name: String
    let isDir: Bool
    var children: [String: ArchiveNode] = [:]

    var sortedChildren: [ArchiveNode] {
        children.values.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

private func buildTree(from entries: [ArchiveEntry]) -> ArchiveNode {
    var root = ArchiveNode(name: "", isDir: true)

    for entry in entries {
        let parts = entry.name
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
        guard !parts.isEmpty else { continue }

            insertNode(into: &root, parts: parts, isDir: entry.isDir)
    }

    // If single top-level directory, return it directly
    if root.children.count == 1, let only = root.children.values.first, only.isDir {
        return only
    }
    return root
}

private func insertNode(into node: inout ArchiveNode, parts: [String], isDir: Bool) {
    guard let first = parts.first else { return }
    let remaining = Array(parts.dropFirst())
    let childIsDir = remaining.isEmpty ? isDir : true

    if node.children[first] == nil {
        node.children[first] = ArchiveNode(name: first, isDir: childIsDir)
    }

    if !remaining.isEmpty {
        insertNode(into: &node.children[first]!, parts: remaining, isDir: isDir)
    }
}

// MARK: - Tree row view

private struct ArchiveNodeRow: View {
    let node: ArchiveNode
    let depth: Int
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.isDir {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                        .foregroundStyle(.tertiary)
                        .onTapGesture { expanded.toggle() }
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: node.isDir ? "folder.fill" : "doc")
                    .font(.caption)
                    .foregroundStyle(node.isDir ? .orange : .secondary)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isDir { expanded.toggle() }
            }

            if expanded {
                ForEach(node.sortedChildren) { child in
                    ArchiveNodeRow(node: child, depth: depth + 1)
                }
            }
        }
    }
}
