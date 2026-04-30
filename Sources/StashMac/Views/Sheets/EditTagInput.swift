import SwiftUI

struct EditTagInput: View {
    @Binding var text: String
    let allTags: [StashTag]
    let existingTags: [String]
    let onCommit: (String) -> Void

    @State private var activeIndex = 0
    @State private var isEditing = false

    private var filtered: [StashTag] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return [] }
        return allTags
            .filter { $0.name.lowercased().contains(query) && !existingTags.contains($0.name) }
            .prefix(6)
            .map { $0 }
    }

    private var showSuggestions: Bool {
        isEditing && !filtered.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FilterField(
                        placeholder: "",
                        text: $text,
                        isBordered: true,
                        onSubmit: commitCurrent,
                        onKey: { key in
                            switch key {
                            case .tab:
                                if !showSuggestions { return false }
                                if filtered.count == 1 {
                                    text = filtered[0].name
                                    return true
                                }
                                activeIndex = clamp(activeIndex + 1)
                                return true
                            case .shiftTab:
                                if !showSuggestions { return false }
                                activeIndex = clamp(activeIndex - 1)
                                return true
                            case .arrowDown:
                                if !showSuggestions { return false }
                                activeIndex = clamp(activeIndex + 1)
                                return true
                            case .arrowUp:
                                if !showSuggestions { return false }
                                activeIndex = clamp(activeIndex - 1)
                                return true
                            case .escape:
                                text = ""
                                return true
                            default:
                                return false
                            }
                        },
                        onBeginEditing: { isEditing = true },
                        onEndEditing: { isEditing = false }
                    )
                    .onChange(of: text) { _, _ in
                        activeIndex = 0
                    }
                }
                Button("Add", action: commitCurrent)
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

    private func clamp(_ i: Int) -> Int {
        let count = filtered.count
        if count == 0 { return 0 }
        return min(max(i, 0), count - 1)
    }

    /// If a suggestion is highlighted, commit it as a single tag. Otherwise
    /// split the free-text on commas, trim each piece, and commit one tag
    /// per non-empty piece — so `"bleep,blorp"` adds two tags.
    private func commitCurrent() {
        if showSuggestions, activeIndex < filtered.count {
            onCommit(filtered[activeIndex].name)
            return
        }
        let tags = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for tag in tags {
            onCommit(tag)
        }
    }
}
