import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 128pt thumbnail square + Finder-style overlay action menu and
/// drop target. The "Thumbnail" section title is intentionally
/// dropped — when an image is showing it labels itself, and when
/// none exists the type-icon placeholder makes the affordance clear.
///
/// Optional `onPlay` overlays a play-button when set (used by
/// video-file tap-to-play).
struct ThumbnailTile: View {
    let item: StashItem
    @Binding var importDialogPresented: Bool
    var onPlay: (() -> Void)? = nil
    @Environment(StashStore.self) private var store

    /// Loaded thumbnail image. Reset whenever the item or its
    /// thumbnailPath changes so the .task below reloads. Decoded
    /// off-thread to keep navigation responsive — previously we
    /// loaded inline in body via NSImage(contentsOf:), which
    /// stalled the main thread for the duration of the file read +
    /// image decode on every selection change. With many items
    /// (and especially with larger og:image thumbnails) the
    /// cumulative effect read as the sidebar going "disabled"
    /// because the runloop was busy.
    @State private var loadedThumb: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .symbolRenderingMode(.palette)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("Play video")
            }
            actionsButton
                .padding(6)
        }
        .frame(width: 128, height: 128)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.setThumbnail(itemID: item.id, fileURL: url)
            return true
        }
        .help(item.thumbnailPath != nil ? "Drop an image to replace" : "Drop an image to set")
        // Keyed on (id, thumbnailPath) — re-runs both when the user
        // navigates to a different item and when the same item's
        // thumbnail is regenerated/cleared/imported. The id-only
        // key would miss thumbnail mutations on the focused item.
        .task(id: thumbnailIdentity) {
            await loadThumbnail()
        }
    }

    /// Identity used by .task(id:) — combines the item id with the
    /// thumbnail path so changes to either trigger a reload.
    private var thumbnailIdentity: String {
        item.id + "|" + (item.thumbnailPath ?? "")
    }

    @ViewBuilder
    private var base: some View {
        if let thumb = loadedThumb {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            TypeStyledPlaceholder(item: item)
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Resolve the thumbnail path and load via the shared cache.
    /// Cache hits return synchronously; misses decode off-thread.
    /// Either way, the state set is dropped if the user has
    /// navigated to a different item mid-load.
    private func loadThumbnail() async {
        guard let rel = item.thumbnailPath,
              let url = FilePathResolver.resolveRelative(rel) else {
            loadedThumb = nil
            return
        }
        let path = url.path
        if let cached = ThumbnailCache.shared.image(forPath: path) {
            loadedThumb = cached
            return
        }
        let capturedID = item.id
        let img = await ThumbnailCache.shared.loadAsync(path: path)
        guard capturedID == item.id else { return }
        loadedThumb = img
    }

    private var actionsButton: some View {
        Menu {
            if canGenerate {
                Button(item.thumbnailPath == nil ? "Generate" : "Regenerate") {
                    store.generateThumbnail(for: item)
                }
            }
            if canImport {
                Button(item.thumbnailPath == nil ? "Import…" : "Re-import…") {
                    importDialogPresented = true
                }
            }
            Button("Use file…") {
                chooseLocalFile()
            }
            if item.thumbnailPath != nil {
                Divider()
                Button("Clear", role: .destructive) {
                    store.clearThumbnail(itemID: item.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, .black.opacity(0.55))
                .symbolRenderingMode(.palette)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Thumbnail actions")
    }

    private var canGenerate: Bool {
        switch item.type {
        case .image, .file: return true
        case .url, .snippet, .email: return false
        }
    }

    private var canImport: Bool { item.type == .url }

    private func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            store.setThumbnail(itemID: item.id, fileURL: url)
        }
    }
}

/// Modal dialog backing the "Import…" menu item. Pre-fills with the
/// item's own URL so the common case (use this page's hero image)
/// is one keypress; the user can paste a different page URL or a
/// direct image URL to harvest from somewhere else without changing
/// the stashed link.
struct ThumbnailImportSheet: View {
    let item: StashItem
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL: String

    init(item: StashItem, onCommit: @escaping (String) -> Void) {
        self.item = item
        self.onCommit = onCommit
        _sourceURL = State(initialValue: item.url ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Thumbnail")
                .font(.headline)
            Text("Fetch the source URL and pick its best thumbnail. Defaults to this item's URL — change it to harvest from a different page or paste a direct image URL.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FilterField(
                placeholder: "https://…",
                text: $sourceURL,
                autoFocus: true,
                onSubmit: commit
            )
            .frame(width: 480)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedURL.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmedURL: String {
        sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmedURL.isEmpty else { return }
        onCommit(trimmedURL)
        dismiss()
    }
}
