import SwiftUI

struct ItemRow: View {
    @Environment(StashStore.self) private var store
    let item: StashItem
    /// Shared "currently shown popover" state owned by ItemListView so
    /// clicking icon B atomically dismisses A's popover. nil means
    /// no popover is showing.
    @Binding var shownThumbnailID: String?

    private var isUnseen: Bool {
        store.isUnseen(item.id)
    }

    private var isPopoverShown: Bool {
        shownThumbnailID == item.id
    }

    private var hasThumbnail: Bool { thumbnailURL() != nil }

    private func thumbnailURL() -> URL? {
        guard let rel = item.thumbnailPath,
              let url = FilePathResolver.resolveRelative(rel),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        HStack(spacing: 10) {
            leading

            // Title + sub-line. Hit-testing disabled on this whole
            // VStack so its Text views don't swallow clicks before
            // List's row container sees them — without this, a
            // click that lands on the title or tags went to the
            // Text and never reached selection, while padding
            // clicks worked normally. Leading icon stays
            // hit-testable because it has its own popover gesture.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Favorite indicator — small filled star to
                    // the left of the title when the canonical
                    // `fav` tag is present. Read-only here; the
                    // detail toolbar (or ⌘F there) is where the
                    // toggle happens.
                    if item.tags?.contains(where: { $0.name == FavoriteTag.name }) ?? false {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    Text(item.title)
                        .lineLimit(1)
                        .font(.body)
                        .fontWeight(isUnseen ? .bold : .regular)
                        .foregroundStyle(isUnseen ? .blue : .primary)
                    // In-flight identify indicator. Reads from the
                    // store's identifyingItemIDs set — populated when
                    // right-click → Identify with X fires, cleared on
                    // success/failure. Small enough to not shift the
                    // row layout, prominent enough to signal "Stash
                    // is still working on this."
                    if store.identifyingItemIDs.contains(item.id) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    }
                }

                HStack(spacing: 0) {
                    ForEach(Array(subtitleElements.enumerated()), id: \.element) { index, element in
                        if index > 0 {
                            Spacer()
                        }
                        switch element {
                        case .language(let lang):
                            Text(lang)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.blue)
                        case .emailFrom(let from):
                            Text(from)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .duration(let dur):
                            Text(dur)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .fileSize(let size):
                            Text(size)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Text(item.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                
                if let tags = item.tags, !tags.isEmpty {
                    Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                        .kerning(0.5)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if isAudioOrVideo {
                store.loadMediaDuration(id: item.id)
            }
        }
    }

    /// Leading type-icon. Clicking it opens / toggles the thumbnail
    /// popover. Pointer turns to a hand on hover when a thumbnail
    /// exists so the affordance is obvious.
    @ViewBuilder
    private var leading: some View {
        Image(systemName: item.type.icon)
            .foregroundStyle(isUnseen ? .primary : .secondary)
            .frame(width: 20)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hasThumbnail else {
                    NSCursor.pop()
                    return
                }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            // `.highPriorityGesture` instead of `.onTapGesture`:
            // SwiftUI's `List(selection:)` swallows clicks on the
            // already-selected row (the first item gets default
            // selection on appear, so its icon never received the tap).
            // High-priority runs before List's selection handler.
            .highPriorityGesture(
                TapGesture().onEnded {
                    guard hasThumbnail else { return }
                    if isPopoverShown {
                        shownThumbnailID = nil
                    } else {
                        shownThumbnailID = item.id
                    }
                }
            )
            .popover(
                isPresented: Binding(
                    get: { isPopoverShown },
                    set: { newValue in
                        if !newValue && isPopoverShown {
                            shownThumbnailID = nil
                        }
                    }
                ),
                arrowEdge: .leading
            ) {
                ItemRowPopover(item: item)
                    .onTapGesture {
                        shownThumbnailID = nil
                    }
            }
    }

    private enum SubtitleElement: Hashable {
        case language(String)
        case emailFrom(String)
        case duration(String)
        case fileSize(String)
    }

    private var isAudioOrVideo: Bool {
        guard item.type == .file, let mime = item.mimeType else { return false }
        return mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    private var durationLabel: String? {
        guard let dur = store.durationWrapper(for: item.id).value, dur > 0 else { return nil }
        return formatDuration(dur)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSecs = Int(round(seconds))
        let h = totalSecs / 3600
        let m = (totalSecs % 3600) / 60
        let s = totalSecs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    private var subtitleElements: [SubtitleElement] {
        var list: [SubtitleElement] = []
        if let lang = item.language {
            list.append(.language(lang))
        }
        if item.type == .email, let from = item.fromName {
            list.append(.emailFrom(from))
        }
        if isAudioOrVideo, let durStr = durationLabel {
            list.append(.duration(durStr))
        }
        if let sizeStr = item.humanFileSize {
            list.append(.fileSize(sizeStr))
        }
        return list
    }
}

/// Extracted to ensure image decoding and markdown parsing only happen
/// when the popover is actually being rendered.
private struct ItemRowPopover: View {
    let item: StashItem
    
    var body: some View {
        if let url = thumbnailURL(),
           let image = ThumbnailCache.loadOriented(from: url) {
            let trimmedNotes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasNotes = !trimmedNotes.isEmpty
            Group {
                if hasNotes {
                    VStack(alignment: .leading, spacing: 0) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 260)
                        Divider()
                        ScrollView {
                            MarkdownText(trimmedNotes, isSelectable: false)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 240)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 260)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 360, maxHeight: 360)
                }
            }
        }
    }

    private func thumbnailURL() -> URL? {
        guard let rel = item.thumbnailPath,
              let url = FilePathResolver.resolveRelative(rel),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
