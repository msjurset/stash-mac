import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "com.msjurseth.stash", category: "preview")

/// Carousel/filmstrip preview for items that carry multiple attached
/// photos or audio tracks beyond the primary `store_path`.
///
/// For dual-source audio stashes, this allows selecting and playing
/// the raw phone/watch tracks independently of the master mix.
struct MultiFilePreview: View {
    let item: StashItem
    @Environment(StashStore.self) private var store

    /// Selected slot in the carousel. 
    @State private var selectedID: String? = nil
    @State private var editingCaptionID: String? = nil
    @State private var draftCaption: String = ""
    @State private var xrayActive: Bool = false
    @State private var confirmDeleteIndex: Int? = nil

    var body: some View {
        Group {
            if xrayActive {
                XRayAudioView(item: item, onDismiss: { xrayActive = false })
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                        removal: .opacity
                    ))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    mainPreview
                    filmstrip
                }
            }
        }
        .onChange(of: item.id, initial: true) { _, _ in 
            selectedID = allSlots.first?.id
            xrayActive = false
        }
        .onChange(of: allSlots.map { $0.id }) { _, newIDs in
            if let sel = selectedID, !newIDs.contains(sel) {
                selectedID = newIDs.first
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .alert("Delete Attached File", isPresented: .init(
            get: { confirmDeleteIndex != nil },
            set: { if !$0 { confirmDeleteIndex = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let index = confirmDeleteIndex {
                    store.detachFile(from: item.id, index: index)
                }
                confirmDeleteIndex = nil
            }
            Button("Cancel", role: .cancel) {
                confirmDeleteIndex = nil
            }
        } message: {
            Text("Are you sure? This will effectively delete this image from the stash item.")
        }
    }

    @ViewBuilder
    private var mainPreview: some View {
        if let slot = activeSlot, let url = slot.url {
            if isAudioSlot(slot) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(slot.caption ?? (slot.isPrimary ? "Master Mix" : url.lastPathComponent))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        if item.isMultiSourceAudio {
                            Button(action: { withAnimation { xrayActive = true } }) {
                                Label("X-Ray", systemImage: "waveform.path")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .help("Open multi-track analyzer")
                        }
                    }
                    
                    DirectMediaPlayer(
                        url: url,
                        isVideo: false,
                        mimeHint: slot.mimeType
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .padding()
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ImagePreviewSection(fileURL: url, allURLs: allSlots.compactMap { $0.url })
            }
        } else if !anySlotResolves, let fallback = thumbnailFallbackURL {
            VStack(alignment: .leading, spacing: 6) {
                ImagePreviewSection(fileURL: fallback)
                MissingBlobBanner(itemID: item.id)
            }
        } else {
            placeholder("Preview not available")
        }
    }

    private var anySlotResolves: Bool {
        allSlots.contains { $0.url != nil }
    }

    private var thumbnailFallbackURL: URL? {
        guard let rel = item.thumbnailPath, !rel.isEmpty,
              let url = FilePathResolver.resolveRelative(rel),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                let slots = allSlots
                ForEach(slots) { slot in
                    slotThumbnail(slot: slot)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func slotThumbnail(slot: Slot) -> some View {
        let isActive = (slot.id == selectedID)
        VStack(spacing: 4) {
            Group {
                if let url = slot.url {
                    if isAudioSlot(slot) {
                        ZStack {
                            Rectangle().fill(.secondary.opacity(0.15))
                            Image(systemName: "waveform")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        AsyncThumbnail(fileURL: url)
                    }
                } else {
                    placeholder("?")
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isActive ? 3 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if slot.isPrimary {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6))
                        .clipShape(Circle())
                        .padding(4)
                        .help("Master Mix")
                }
            }
            .onTapGesture { selectedID = slot.id }

            if editingCaptionID == slot.id {
                InlineEditField(
                    text: $draftCaption,
                    placeholder: "caption…",
                    font: .preferredFont(forTextStyle: .caption2),
                    alignment: .center,
                    onCommit: {
                        if slot.isPrimary {
                            store.editFileCaption(in: item.id, index: 0, caption: draftCaption)
                        } else if let attachmentIndex = slot.attachmentIndex {
                            store.editFileCaption(in: item.id, index: attachmentIndex, caption: draftCaption)
                        }
                        editingCaptionID = nil
                    },
                    onCancel: {
                        editingCaptionID = nil
                    }
                )
                .frame(width: 80, height: 24)
            } else {
                let textValue = (slot.caption?.isEmpty == false) ? slot.caption! : (slot.isPrimary ? "Master" : "add caption")
                Text(textValue)
                    .font(.system(size: 10))
                    .foregroundStyle(slot.caption?.isEmpty == false ? .secondary : .quaternary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 80, height: 18)
                    .help("Double-click to edit caption")
                    .onTapGesture(count: 2) {
                        draftCaption = slot.caption ?? ""
                        editingCaptionID = slot.id
                    }
            }
        }
        .contextMenu { slotMenu(slot: slot) }
    }

    @ViewBuilder
    private func slotMenu(slot: Slot) -> some View {
        if isImageSlot(slot), let url = slot.url {
            Button("Set as Desktop Background") {
                for screen in NSScreen.screens {
                    try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                }
            }
            Divider()
        }

        if slot.isPrimary {
            Text("Primary file")
                .foregroundStyle(.secondary)
        } else if let attachmentIndex = slot.attachmentIndex {
            Button("Set as Primary") {
                store.promoteFile(in: item.id, index: attachmentIndex)
            }
            Divider()
            Button("Delete...", role: .destructive) {
                confirmDeleteIndex = attachmentIndex
            }
        }
    }

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

    private func isAudioSlot(_ slot: Slot) -> Bool {
        if let mime = slot.mimeType, isAudioMIME(mime) { return true }
        if let url = slot.url, url.pathExtension.lowercased() == "m4a" { return true }
        // Fallback for blobs: if the item itself is an audio type or the filename/caption
        // implies audio, treat it as such.
        if item.type == .file && (item.mimeType?.hasPrefix("audio/") == true) { return true }
        if let caption = slot.caption?.lowercased(),
           (caption.contains("raw") || caption.contains("track") || caption.contains("phone") || caption.contains("watch")) {
            return true
        }
        return false
    }

    private func isImageSlot(_ slot: Slot) -> Bool {
        if let mime = slot.mimeType, mime.hasPrefix("image/") { return true }
        if let url = slot.url {
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext)
        }
        return false
    }

    private var activeSlot: Slot? {
        let slots = allSlots
        return slots.first { $0.id == selectedID }
    }

    private var allSlots: [Slot] {
        var slots: [Slot] = []
        if let sp = item.storePath, !sp.isEmpty {
            slots.append(Slot(
                id: "primary",
                isPrimary: true,
                attachmentIndex: nil,
                url: FilePathResolver.resolve(storePath: sp),
                caption: item.caption,
                mimeType: item.mimeType
            ))
        }
        if let files = item.files {
            let sortedFiles = files.sorted {
                if $0.position == $1.position {
                    return $0.id < $1.id
                }
                return $0.position < $1.position
            }
            for (i, f) in sortedFiles.enumerated() {
                slots.append(Slot(
                    id: "\(f.id)",
                    isPrimary: false,
                    attachmentIndex: i + 1,
                    url: FilePathResolver.resolve(storePath: f.storePath),
                    caption: f.caption,
                    mimeType: f.mimeType
                ))
            }
        }
        return slots
    }

    private struct Slot: Identifiable {
        let id: String
        let isPrimary: Bool
        let attachmentIndex: Int?
        let url: URL?
        let caption: String?
        let mimeType: String?
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
            let img = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.loadOriented(from: fileURL)
            }.value
            await MainActor.run { image = img }
        }
    }
}
