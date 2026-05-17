import SwiftUI

struct EditItemSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(AIPrefsStore.self) private var aiPrefs
    @Environment(\.dismiss) private var dismiss

    let item: StashItem
    @State private var title: String
    @State private var url: String
    @State private var note: String
    @State private var extractedText: String
    @State private var newTag = ""
    @State private var tagsToAdd: [String] = []
    @State private var tagsToRemove: [String] = []
    @State private var collection = ""
    @State private var isIdentifying = false
    @State private var identifyError: String?
    @State private var latText: String
    @State private var lonText: String
    @State private var locationSource: String
    @State private var showLocationMap = false

    init(item: StashItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _url = State(initialValue: item.url ?? "")
        _note = State(initialValue: item.notes ?? "")
        _extractedText = State(initialValue: item.extractedText ?? "")
        _collection = State(initialValue: item.collectionNames.first ?? "")
        // Empty string = "no location" — both fields blank means we
        // send --clear-location, both populated means
        // --location lat,lon. Mixed (one filled, one empty) gets
        // surfaced as a save-time validation error.
        _latText = State(initialValue: item.location.map { String($0.lat) } ?? "")
        _lonText = State(initialValue: item.location.map { String($0.lon) } ?? "")
        _locationSource = State(initialValue: item.location?.source ?? "")
    }

    var currentTags: [String] {
        var tags = item.tagNames
        tags.append(contentsOf: tagsToAdd)
        tags.removeAll { tagsToRemove.contains($0) }
        return tags
    }

    var body: some View {
        // Action bar pinned at the bottom outside the ScrollView so
        // Cancel / Save never scroll out of reach regardless of how
        // much content the form holds (Notes can grow large after an
        // Identify run, Tags can be many, etc.).
        VStack(spacing: 0) {
            ScrollView {
                formContent
                    .padding()
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 720)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Image strip for multi-file items: shows primary +
            // every attached file inline, lets the user pick a new
            // cover, and surfaces the carousel at the top of the
            // edit dialog so the photos are at hand while editing.
            if item.type == .image {
                imageStrip
            }

            StashField("Title", text: $title)

            // Identify-with-AI row — image items only, key
            // configured. Fills Title (when blank) and appends to
            // Notes on the local editor draft, so the user can
            // review / tweak before hitting Save. Same fill rules
            // as the right-click → Identify path.
            if item.type == .image, aiPrefs.hasKey {
                identifyRow
            }

            // URL is editable for any item that already has one (URL
            // captures, files saved from a URL, emails). Hidden when
            // empty so the field doesn't add noise to snippet edits.
            if !item.url.isNilOrEmpty || item.type == .url {
                StashField("URL", text: $url)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Expands while focused so long Gemini-generated
                // notes stay readable without scrolling the inner
                // editor. Collapses back when focus leaves.
                StashTextEditor(text: $note,
                                idleHeight: 160,
                                focusedHeight: 360)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Extracted Text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StashTextEditor(text: $extractedText)
                    .frame(minHeight: 100)
            }

            locationRow

            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(currentTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                                    .kerning(0.5)
                                .font(.callout)
                            Button {
                                if tagsToAdd.contains(tag) {
                                    tagsToAdd.removeAll { $0 == tag }
                                } else {
                                    tagsToRemove.append(tag)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                    }
                }
                EditTagInput(
                    text: $newTag,
                    allTags: store.tags,
                    existingTags: currentTags,
                    onCommit: { tag in
                        let trimmed = tag.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, !currentTags.contains(trimmed) {
                            tagsToAdd.append(trimmed)
                        }
                        newTag = ""
                    }
                )
            }

            HStack {
                Text("Collection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $collection) {
                    Text("None").tag("")
                    ForEach(store.collections) { col in
                        Text(col.name).tag(col.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

        }
    }

    /// Two-field editor + clear button for the item's location.
    /// Empty fields mean "no location". Hidden for snippet items —
    /// geo doesn't fit that type.
    @ViewBuilder
    private var locationRow: some View {
        if item.type != .snippet {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !locationSource.isEmpty {
                        Text(locationSource)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let coord = currentLatLon() {
                        Button {
                            showLocationMap = true
                        } label: {
                            Image(systemName: "scope")
                        }
                        .buttonStyle(.borderless)
                        .help("Preview on a map")
                        .popover(isPresented: $showLocationMap, arrowEdge: .top) {
                            LocationMapPopover(lat: coord.lat, lon: coord.lon)
                        }
                    }
                    if !latText.isEmpty || !lonText.isEmpty {
                        Button("Clear") {
                            latText = ""
                            lonText = ""
                            locationSource = ""
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                HStack(spacing: 8) {
                    FilterField(
                        placeholder: "lat",
                        text: $latText,
                        isBordered: true,
                        backgroundColor: .textBackgroundColor
                    )
                    .frame(height: 22)
                    FilterField(
                        placeholder: "lon",
                        text: $lonText,
                        isBordered: true,
                        backgroundColor: .textBackgroundColor
                    )
                    .frame(height: 22)
                }
            }
        }
    }

    /// Parses the two text fields into a coordinate pair when both
    /// hold valid decimal-degree values within the geographic range.
    /// Returns nil when either field is empty or out-of-range so the
    /// map button doesn't appear for half-finished edits.
    private func currentLatLon() -> (lat: Double, lon: Double)? {
        let lt = latText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ln = lonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lat = Double(lt), let lon = Double(ln),
              (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return (lat, lon)
    }

    /// Horizontal strip of every photo on the item — primary plus
    /// each attached file. Tapping a non-primary tile promotes it
    /// to be the new cover; primary is badged with a small star.
    /// Keeps the carousel at the top of the dialog so the photos
    /// stay visible while you edit title / notes.
    @ViewBuilder
    private var imageStrip: some View {
        let slots: [ImageSlot] = buildImageSlots()
        if !slots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(slots) { slot in
                        VStack(spacing: 3) {
                            Group {
                                if let url = slot.url, let img = NSImage(contentsOf: url) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.2)
                                }
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(slot.isPrimary ? Color.accentColor
                                            : Color.secondary.opacity(0.3),
                                            lineWidth: slot.isPrimary ? 2 : 1)
                            )
                            .overlay(alignment: .topTrailing) {
                                if slot.isPrimary {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                        .padding(3)
                                        .background(.black.opacity(0.5), in: Circle())
                                        .padding(3)
                                }
                            }
                            Text(slot.isPrimary ? "cover"
                                 : (slot.caption?.isEmpty == false ? slot.caption! : "—"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 80)
                        }
                        .onTapGesture {
                            if let idx = slot.attachmentIndex, !slot.isPrimary {
                                store.promoteFile(in: item.id, index: idx)
                            }
                        }
                        .help(slot.isPrimary ? "Cover photo" : "Click to set as cover")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Per-tile model for the image strip — primary slot first,
    /// attached files following in carousel order. `attachmentIndex`
    /// is nil for the primary; for attachments it's the 1-based
    /// index expected by store.promoteFile.
    private struct ImageSlot: Identifiable {
        let id: String
        let isPrimary: Bool
        let attachmentIndex: Int?
        let url: URL?
        let caption: String?
    }

    private func buildImageSlots() -> [ImageSlot] {
        var out: [ImageSlot] = []
        if let sp = item.storePath, !sp.isEmpty {
            out.append(ImageSlot(
                id: "primary",
                isPrimary: true,
                attachmentIndex: nil,
                url: FilePathResolver.resolve(storePath: sp),
                caption: nil,
            ))
        }
        if let files = item.files {
            for (i, f) in files.enumerated() {
                out.append(ImageSlot(
                    id: "f-\(f.id)",
                    isPrimary: false,
                    attachmentIndex: i + 1,
                    url: FilePathResolver.resolve(storePath: f.storePath),
                    caption: f.caption,
                ))
            }
        }
        return out
    }

    private var identifyRow: some View {
        // "Re-identify" when the item already has AI-style content
        // populated. Heuristic: any non-empty title OR notes implies
        // we (or the user) have content worth refreshing on top of.
        // Otherwise show "Identify" as the first-time action label.
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let verb = hasContent ? "Re-identify" : "Identify"
        return HStack(spacing: 8) {
            Button {
                identify()
            } label: {
                HStack(spacing: 6) {
                    if isIdentifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isIdentifying
                         ? "\(verb)ing…"
                         : "\(verb) with \(aiPrefs.activeProvider.displayName)")
                }
            }
            .disabled(isIdentifying)
            .help("\(verb) using every photo on this item via the active AI provider")
            if let identifyError {
                Text(identifyError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private func identify() {
        guard let storePath = item.storePath, !storePath.isEmpty,
              let fileURL = FilePathResolver.resolve(storePath: storePath)
        else {
            identifyError = "Couldn't resolve the image file on disk."
            return
        }
        let provider = aiPrefs.activeProvider
        let key = aiPrefs.apiKey
        let prompt = aiPrefs.promptText
        let mime = item.mimeType ?? "image/jpeg"
        // Bundle primary + attached files so multi-photo items
        // identify with full context. Same logic as the right-click
        // → Identify path in StashStore.
        let attachedURLs: [(URL, String)] = (item.files ?? []).compactMap { f in
            FilePathResolver.resolve(storePath: f.storePath).map { ($0, f.mimeType ?? "image/jpeg") }
        }

        isIdentifying = true
        identifyError = nil

        Task {
            defer { Task { @MainActor in isIdentifying = false } }
            do {
                let resolved = try await AIKeyResolver.resolve(key)
                var images: [AIImage] = []
                let primary = try Data(contentsOf: fileURL)
                images.append(AIImage(data: primary, mimeType: mime))
                for (u, m) in attachedURLs {
                    let data = try Data(contentsOf: u)
                    images.append(AIImage(data: data, mimeType: m))
                }
                // Single-image identify: send the original at full
                // quality. Multi-image: downscale each so the
                // bundle fits comfortably in the request budget.
                let sendImages = images.count > 1
                    ? images.map { downscaleForIdentify($0) }
                    : images
                let result = try await provider.identify(
                    apiKey: resolved,
                    images: sendImages,
                    promptText: prompt
                )
                await MainActor.run {
                    // Always replace Title with the identified value
                    // here — unlike the right-click path (which writes
                    // immediately to the CLI), the dialog is a draft.
                    // The user reviews and clicks Save or Cancel, so
                    // overwriting placeholder titles like "unidentified"
                    // / "IMG_1234.jpg" / etc. is the expected outcome.
                    if let t = result.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty {
                        title = t
                    }
                    // Append to Notes with a blank-line separator so
                    // repeat identifies don't lose earlier output.
                    let existing = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    note = existing.isEmpty ? result.notes : existing + "\n\n" + result.notes
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run {
                    identifyError = msg
                }
            }
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !currentTags.contains(tag) else { return }
        tagsToAdd.append(tag)
        newTag = ""
    }

    private func save() {
        let t = title != item.title ? title : nil
        let n = note != (item.notes ?? "") ? note : nil
        let e = extractedText != (item.extractedText ?? "") ? extractedText : nil
        let u = url != (item.url ?? "") ? url : nil
        let c = collection.isEmpty ? nil : collection

        // Location diff: empty in both fields → clear (if there was
        // one before); valid lat,lon → set as manual; mixed (one
        // filled / one empty) silently no-ops rather than dismissing
        // with a half-edit — keeps the save button forgiving.
        let trimmedLat = latText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLon = lonText.trimmingCharacters(in: .whitespacesAndNewlines)
        var newLocation: ItemLocation? = nil
        var shouldClearLocation = false
        if trimmedLat.isEmpty && trimmedLon.isEmpty {
            if item.location != nil {
                shouldClearLocation = true
            }
        } else if let lat = Double(trimmedLat), let lon = Double(trimmedLon),
                  (-90...90).contains(lat), (-180...180).contains(lon) {
            let existing = item.location
            // Avoid resending an unchanged value as a no-op manual
            // edit — keeps EXIF / capture sources pinned.
            if existing == nil || existing?.lat != lat || existing?.lon != lon {
                newLocation = ItemLocation(lat: lat, lon: lon, source: "manual")
            }
        }

        store.editItem(
            id: item.id,
            title: t,
            note: n,
            extractedText: e,
            url: u,
            addTags: tagsToAdd,
            removeTags: tagsToRemove,
            collection: c,
            location: newLocation,
            clearLocation: shouldClearLocation
        )
        dismiss()
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
