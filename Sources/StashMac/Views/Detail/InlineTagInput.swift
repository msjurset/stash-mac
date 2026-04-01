import SwiftUI

struct InlineTagInput: View {
    @Binding var text: String
    let allTags: [StashTag]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var showSuggestions = false
    @State private var activeIndex = -1
    @FocusState private var isFocused: Bool

    private var filtered: [StashTag] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return [] }
        return allTags.filter { $0.name.lowercased().contains(query) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("tag", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
                .frame(width: 120)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onChange(of: text) { _, _ in
                    showSuggestions = !filtered.isEmpty
                    activeIndex = -1
                }
                .onSubmit {
                    if activeIndex >= 0, activeIndex < filtered.count {
                        onCommit(filtered[activeIndex].name)
                    } else {
                        onCommit(text)
                    }
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
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

            if showSuggestions && !filtered.isEmpty {
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
                .frame(width: 160)
                .padding(.top, 2)
            }
        }
    }
}
