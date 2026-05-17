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

    init(item: StashItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _url = State(initialValue: item.url ?? "")
        _note = State(initialValue: item.notes ?? "")
        _extractedText = State(initialValue: item.extractedText ?? "")
        _collection = State(initialValue: item.collectionNames.first ?? "")
    }

    var currentTags: [String] {
        var tags = item.tagNames
        tags.append(contentsOf: tagsToAdd)
        tags.removeAll { tagsToRemove.contains($0) }
        return tags
    }

    var body: some View {
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
                    .frame(minHeight: 60)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Extracted Text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StashTextEditor(text: $extractedText)
                    .frame(minHeight: 60)
            }

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

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480, height: 550)
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
                    // Fill Title only when blank — never clobber a
                    // user-typed value, even mid-edit.
                    let currentTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if currentTitle.isEmpty, let t = result.title, !t.isEmpty {
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

        store.editItem(id: item.id, title: t, note: n, extractedText: e, url: u, addTags: tagsToAdd, removeTags: tagsToRemove, collection: c)
        dismiss()
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
