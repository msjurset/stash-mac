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

                HStack(spacing: 6) {
                    if let lang = item.language {
                        Text(lang)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.blue)
                    }
                    if item.type == .email, let from = item.fromName {
                        Text(from)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let tags = item.tags, !tags.isEmpty {
                        Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                            .kerning(0.5)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .allowsHitTesting(false)

            Spacer()

            Text(item.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                popoverContent
            }
    }

    /// Popover layout — sized modestly so it doesn't dominate the
    /// list. Notes use `.callout` (12pt) for a quieter visual weight
    /// vs. the title-sized list rows.
    ///  - **No notes** → image-only, zero padding. Popover hugs the
    ///    image with the OS's standard chrome.
    ///  - **With notes** → 260pt-wide popover. Image fills the full
    ///    width (top edge flush). Notes flow below with 10pt inset.
    ///    Long notes scroll within a 240pt cap.
    @ViewBuilder
    private var popoverContent: some View {
        if let url = thumbnailURL(),
           // ThumbnailCache.loadOriented honors EXIF rotation. Bare
           // NSImage(contentsOf:) left portrait-shot images sideways
           // in this hover popover.
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
            .contentShape(Rectangle())
            .onTapGesture {
                shownThumbnailID = nil
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
