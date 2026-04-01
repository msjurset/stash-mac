import SwiftUI

struct EditTagInput: View {
    @Binding var text: String
    let allTags: [StashTag]
    let existingTags: [String]
    let onCommit: (String) -> Void

    @State private var activeIndex = -1
    @FocusState private var isFocused: Bool

    private var filtered: [StashTag] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return [] }
        return allTags
            .filter { $0.name.lowercased().contains(query) && !existingTags.contains($0.name) }
            .prefix(6)
            .map { $0 }
    }

    private var showSuggestions: Bool {
        isFocused && !filtered.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .onChange(of: text) { _, _ in
                            activeIndex = -1
                        }
                        .onSubmit {
                            if activeIndex >= 0, activeIndex < filtered.count {
                                onCommit(filtered[activeIndex].name)
                            } else {
                                onCommit(text)
                            }
                        }
                        .onKeyPress(.downArrow) {
                            if !filtered.isEmpty {
                                activeIndex = min(activeIndex + 1, filtered.count - 1)
                            }
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            activeIndex = max(activeIndex - 1, -1)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            text = ""
                            isFocused = false
                            return .handled
                        }
                }
                Button("Add") {
                    if activeIndex >= 0, activeIndex < filtered.count {
                        onCommit(filtered[activeIndex].name)
                    } else {
                        onCommit(text)
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 18)
            }

            if showSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, tag in
                        HStack {
                            Text(tag.name)
                                .font(.callout)
                            Spacer()
                            Text("\(tag.count ?? 0)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == activeIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onCommit(tag.name)
                        }
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 4)
                .padding(.top, 2)
            }
        }
    }
}
