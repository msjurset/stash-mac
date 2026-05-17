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
                StashTextEditor(text: $note)
                    .frame(minHeight: 160)
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

    private var identifyRow: some View {
        HStack(spacing: 8) {
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
                         ? "Identifying…"
                         : "Identify with \(aiPrefs.activeProvider.displayName)")
                }
            }
            .disabled(isIdentifying)
            .help("Fill Title and append to Notes from the active AI provider")
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

        isIdentifying = true
        identifyError = nil

        Task {
            defer { Task { @MainActor in isIdentifying = false } }
            do {
                let resolved = try await AIKeyResolver.resolve(key)
                let bytes = try Data(contentsOf: fileURL)
                let result = try await provider.identify(
                    apiKey: resolved,
                    bytes: bytes,
                    mimeType: mime,
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
