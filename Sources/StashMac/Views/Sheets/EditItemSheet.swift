import SwiftUI

struct EditItemSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: StashItem
    @State private var title: String
    @State private var note: String
    @State private var newTag = ""
    @State private var tagsToAdd: [String] = []
    @State private var tagsToRemove: [String] = []
    @State private var collection = ""

    init(item: StashItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _note = State(initialValue: item.notes ?? "")
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StashTextEditor(text: $note)
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
                HStack {
                    StashField("Add tag", text: $newTag, onSubmit: addTag)
                    Button("Add") { addTag() }
                        .disabled(newTag.isEmpty)
                        .padding(.top, 18)
                }
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
        .frame(width: 480, height: 450)
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
        let c = collection.isEmpty ? nil : collection

        store.editItem(id: item.id, title: t, note: n, addTags: tagsToAdd, removeTags: tagsToRemove, collection: c)
        dismiss()
    }
}
