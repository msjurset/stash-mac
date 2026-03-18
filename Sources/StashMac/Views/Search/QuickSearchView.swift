import SwiftUI

struct QuickSearchView: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StashItem] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search stash...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { selectFirst() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if results.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(height: 200)
            } else {
                List(results) { item in
                    Button {
                        store.selectedItemID = item.id
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: item.type.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(item.title)
                                    .lineLimit(1)
                                if let tags = item.tags, !tags.isEmpty {
                                    Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                                        .kerning(0.5)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(item.type.label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(minHeight: 200, maxHeight: 400)
            }
        }
        .frame(width: 500)
        .onChange(of: query) { _, newQuery in
            debounceSearch(newQuery)
        }
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                let found = try await StashCLI.shared.searchItems(query: query, limit: 20)
                if !Task.isCancelled {
                    results = found
                }
            } catch {
                // Ignore search errors in quick search
            }
        }
    }

    private func selectFirst() {
        if let first = results.first {
            store.selectedItemID = first.id
            dismiss()
        }
    }
}
