import SwiftUI

struct LinkItemSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sourceItemID: String

    @State private var searchText = ""
    @State private var label = ""
    @State private var directed = false
    @State private var searchResults: [StashItem] = []
    @State private var selectedTarget: StashItem?
    @State private var isSearching = false

    private let cli = StashCLI.shared

    var body: some View {
        VStack(spacing: 16) {
            Text("Link Item")
                .font(.headline)

            TextField("Search for target item...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: searchText) {
                    performSearch()
                }

            if !searchResults.isEmpty {
                List(searchResults, selection: Binding(
                    get: { selectedTarget?.id },
                    set: { id in selectedTarget = searchResults.first { $0.id == id } }
                )) { item in
                    HStack {
                        Image(systemName: item.type.icon)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.shortID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(item.id)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if isSearching {
                Text("No results.")
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            }

            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)

            Toggle("Directed link", isOn: $directed)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Link") {
                    if let target = selectedTarget {
                        store.linkItems(from: sourceItemID, to: target.id, label: label.isEmpty ? nil : label, directed: directed)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedTarget == nil)
            }
        }
        .padding()
        .frame(width: 400, height: 450)
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        // Append * to each word for FTS5 prefix matching
        let prefixQuery = query.split(separator: " ").map { "\($0)*" }.joined(separator: " ")
        Task {
            do {
                let results = try await cli.searchItems(query: prefixQuery, limit: 20)
                searchResults = results.filter { $0.id != sourceItemID }
            } catch {
                searchResults = []
            }
        }
    }
}
