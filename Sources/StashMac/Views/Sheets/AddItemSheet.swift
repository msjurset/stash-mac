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
    /// URL paired with the File tab's "or fetch from a URL" row.
    /// Clicking Discover routes this through the FetchURLSheet
    /// rather than the local `stash add` path.
    @State private var fileFetchURL = ""
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
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
                        HStack {
                            StashField(
                                "Or fetch files from a URL",
                                text: $fileFetchURL,
                                prompt: "https://example.com/article"
                            )
                            Button("Discover…") { fetchFromURL() }
                                .padding(.top, 18)
                                .disabled(fileFetchURL.trimmingCharacters(in: .whitespaces).isEmpty)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MultiTagField(text: $tagsString, allTags: store.tags, placeholder: "Comma-separated")
                    }
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
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding()
        }
        .frame(width: 480)
        .frame(minHeight: 400, maxHeight: 520)
    }

    private func submit() {
        let t = title.isEmpty ? nil : title
        let n = note.isEmpty ? nil : note
        let c = collection.isEmpty ? nil : collection

        switch selectedTab {
        case .url:
            store.addURL(url: normalizeURL(urlString), title: t, tags: parsedTags, note: n, collection: c)
        case .file:
            store.addFile(path: filePath, title: t, tags: parsedTags, note: n, collection: c)
        case .snippet:
            store.addSnippet(text: snippetText, title: t, tags: parsedTags, note: n, collection: c)
        }
        dismiss()
    }

    /// Default to `https://` when the user omits the scheme. Anything that
    /// already contains `://` is left alone so `http://`, `ftp://`, etc.
    /// pass through unchanged.
    private func normalizeURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("://") { return trimmed }
        return "https://\(trimmed)"
    }

    private func browseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
        }
    }

    /// Hand off to FetchURLSheet pre-populated with the URL the user
    /// typed into the File tab's "or fetch from a URL" row. Posts the
    /// notification (ContentView listens) and dismisses this sheet —
    /// SwiftUI on macOS doesn't reliably stack two modal sheets, so
    /// we route through dismissal rather than presenting a child.
    private func fetchFromURL() {
        let trimmed = fileFetchURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        NotificationCenter.default.post(
            name: .stashOpenFetchURL,
            object: nil,
            userInfo: ["url": trimmed]
        )
        dismiss()
    }
}
