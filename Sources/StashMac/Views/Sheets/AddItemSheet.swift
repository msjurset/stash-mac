import SwiftUI

struct AddItemSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case url = "URL"
        case file = "File"
        case snippet = "Snippet"
    }

    @State private var selectedTab: Tab = .url
    @State private var urlString = ""
    @State private var filePath = ""
    @State private var snippetText = ""
    @State private var title = ""
    @State private var tagsString = ""
    @State private var note = ""
    @State private var collection = ""

    private var parsedTags: [String] {
        tagsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var canSubmit: Bool {
        switch selectedTab {
        case .url: return !urlString.isEmpty
        case .file: return !filePath.isEmpty
        case .snippet: return !snippetText.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Type", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedTab {
            case .url:
                StashField("URL", text: $urlString, prompt: "https://example.com")
            case .file:
                HStack {
                    StashField("File Path", text: $filePath)
                    Button("Browse...") { browseFile() }
                        .padding(.top, 18)
                }
            case .snippet:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snippet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    StashTextEditor(text: $snippetText)
                        .frame(minHeight: 80)
                }
            }

            Divider()

            StashField("Title", text: $title, prompt: "Optional")
            StashField("Tags", text: $tagsString, prompt: "Comma-separated")
            StashField("Note", text: $note, prompt: "Optional")

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
                ContextualHelpButton(topic: .addingItems)
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
    }

    private func submit() {
        let t = title.isEmpty ? nil : title
        let n = note.isEmpty ? nil : note
        let c = collection.isEmpty ? nil : collection

        switch selectedTab {
        case .url:
            store.addURL(url: urlString, title: t, tags: parsedTags, note: n, collection: c)
        case .file:
            store.addFile(path: filePath, title: t, tags: parsedTags, note: n, collection: c)
        case .snippet:
            store.addSnippet(text: snippetText, title: t, tags: parsedTags, note: n, collection: c)
        }
        dismiss()
    }

    private func browseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
        }
    }
}
