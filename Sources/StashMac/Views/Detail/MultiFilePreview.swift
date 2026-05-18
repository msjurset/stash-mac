import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Carousel/filmstrip preview for items that carry multiple attached
/// photos beyond the primary `store_path` (e.g. mushroom top/side/
/// bottom). Single-file items continue to use ImagePreviewSection
/// directly — this view only renders when `item.files` is populated.
///
/// Drag a file from Finder onto either the main preview or the
/// filmstrip to attach it as another slide. Right-click a strip
/// thumbnail for Set as Primary / Detach actions.
struct MultiFilePreview: View {
    let item: StashItem
    @Environment(StashStore.self) private var store

    /// Selected slot in the carousel. 0 = primary; 1...N = attached
    /// files in `item.files` order. Resets to 0 when the underlying
    /// item changes so a fresh selection always opens on the cover.
    @State private var selected: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainPreview
            filmstrip
        }
        .onChange(of: item.id) { _, _ in selected = 0 }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    @ViewBuilder
    private var mainPreview: some View {
        if let url = activeFileURL {
            ImagePreviewSection(fileURL: url)
        } else if !anySlotResolves, let fallback = thumbnailFallbackURL {
            // Every slot's blob has gone missing on disk (dedup
            // delete, manual cleanup, broken backup restore). Show
            // the cached canonical thumbnail so the user can still
            // identify what the item is, and surface the heal
            // banner so they have a one-click path to refetching.
            VStack(alignment: .leading, spacing: 6) {
                ImagePreviewSection(fileURL: fallback)
                MissingBlobBanner(itemID: item.id)
            }
        } else {
            // Selected slot's blob is missing but other slots still
            // resolve — let the user click another filmstrip tile
            // rather than overlaying a heal banner that doesn't
            // apply to the whole item.
            placeholder("Image not available")
        }
    }

    /// True when at least one slot (primary or attached) resolves to
    /// an on-disk file. Used to decide between the per-slot
    /// "Image not available" placeholder and the item-wide
    /// thumbnail-plus-banner fallback.
    private var anySlotResolves: Bool {
        allSlots.contains { $0.url != nil }
    }

    /// URL of the cached canonical thumbnail (the file stash itself
    /// generated and the list/grid views reuse), or nil if the
    /// thumbnail is missing too.
    private var thumbnailFallbackURL: URL? {
        guard let rel = item.thumbnailPath, !rel.isEmpty,
              let url = FilePathResolver.resolveRelative(rel),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Horizontally-scrolling row of thumbnails — primary first,
    /// then attached files in carousel order. Tap to switch the
    /// main view; right-click for primary/detach actions.
    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(allSlots.indices, id: \.self) { idx in
                    slotThumbnail(slot: allSlots[idx], index: idx)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Single thumbnail tile — outlined when selected, opacity-faded
    /// when its blob is missing, with a caption strip underneath.
    @ViewBuilder
    private func slotThumbnail(slot: Slot, index: Int) -> some View {
        let isActive = (index == selected)
        VStack(spacing: 2) {
            Group {
                if let url = slot.url {
                    AsyncThumbnail(fileURL: url)
                } else {
                    placeholder("?")
                        .frame(width: 64, height: 64)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isActive ? 2 : 1)
            )

            if let caption = slot.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 64)
            } else if slot.isPrimary {
                Text("cover")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onTapGesture { selected = index }
        .contextMenu { slotMenu(slot: slot, index: index) }
    }

    @ViewBuilder
    private func slotMenu(slot: Slot, index: Int) -> some View {
        if slot.isPrimary {
            Text("Primary file")
                .foregroundStyle(.secondary)
        } else if let attachmentIndex = slot.attachmentIndex {
            Button("Set as Primary") {
                store.promoteFile(in: item.id, index: attachmentIndex)
            }
            Divider()
            Button("Detach", role: .destructive) {
                store.detachFile(from: item.id, index: attachmentIndex)
            }
        }
    }

    // MARK: - Drag & drop

    /// Walks the dropped providers, resolves any fileURL payloads,
    /// and calls `attachFile` for each. Multiple files attach as
    /// separate carousel slides in dropped order.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var attached = 0
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                let path = url.path(percentEncoded: false)
                Task { @MainActor in
                    store.attachFile(to: item.id, path: path)
                }
            }
            attached += 1
        }
        return attached > 0
    }

    // MARK: - Helpers

    private var activeFileURL: URL? {
        let slots = allSlots
        guard selected < slots.count else { return nil }
        return slots[selected].url
    }

    /// Combined list — primary (slot 0) followed by every attached
    /// file in carousel order. Keeping them in one array makes
    /// indexing into the filmstrip straightforward.
    private var allSlots: [Slot] {
        var slots: [Slot] = []
        if let sp = item.storePath, !sp.isEmpty {
            slots.append(Slot(
                isPrimary: true,
                attachmentIndex: nil,
                url: FilePathResolver.resolve(storePath: sp),
                caption: nil
            ))
        }
        if let files = item.files {
            for (i, f) in files.enumerated() {
                slots.append(Slot(
                    isPrimary: false,
                    attachmentIndex: i + 1,
                    url: FilePathResolver.resolve(storePath: f.storePath),
                    caption: f.caption
                ))
            }
        }
        return slots
    }

    /// Per-tile model used by the filmstrip — flattens primary +
    /// attached files into one indexable array. `attachmentIndex`
    /// is nil for the primary slot.
    private struct Slot {
        let isPrimary: Bool
        let attachmentIndex: Int?
        let url: URL?
        let caption: String?
    }

    private func placeholder(_ text: String) -> some View {
        ZStack {
            Rectangle().fill(.secondary.opacity(0.15))
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Tiny async-loaded NSImage thumbnail for the filmstrip. Loads
/// off the main thread so building a strip of 10+ slides doesn't
/// stall the view hierarchy.
private struct AsyncThumbnail: View {
    let fileURL: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .task(id: fileURL) {
            // Disk read + decode pushed off main so the carousel
            // scrolls smoothly when there are many slides.
            // ThumbnailCache.loadOriented honors EXIF rotation —
            // bare NSImage(contentsOf:) leaves portrait-shot photos
            // sideways in the filmstrip.
            let img = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.loadOriented(from: fileURL)
            }.value
            await MainActor.run { image = img }
        }
    }
}
