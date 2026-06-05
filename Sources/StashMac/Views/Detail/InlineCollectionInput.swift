import SwiftUI
import AppKit

struct InlineCollectionInput: View {
    @Binding var text: String
    let allCollections: [StashCollection]
    var onBeginEditing: (() -> Void)? = nil
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var activeIndex = 0
    @State private var dropdownOpen = false

    private var currentToken: String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var enteredCollections: Set<String> {
        let parts = text.split(separator: ",").dropLast(text.hasSuffix(",") ? 0 : 1)
        return Set(parts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    private var filtered: [StashCollection] {
        let query = currentToken
        return allCollections
            .filter { col in
                let lower = col.name.lowercased()
                return (query.isEmpty || lower.contains(query)) && !enteredCollections.contains(lower)
            }
            .prefix(6)
            .map { $0 }
    }

    private var showSuggestions: Bool { dropdownOpen && !filtered.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterField(
                placeholder: "collection",
                text: $text,
                font: .preferredFont(forTextStyle: .callout),
                autoFocus: true,
                onSubmit: {
                    if showSuggestions, activeIndex < filtered.count {
                        commitSelection(filtered[activeIndex].name)
                    } else {
                        let current = text
                        onCommit(current)
                    }
                },
                onKey: { key in
                    switch key {
                    case .tab:      return handleTab(reverse: false)
                    case .shiftTab: return handleTab(reverse: true)
                    case .arrowDown: return handleArrow(reverse: false)
                    case .arrowUp:   return handleArrow(reverse: true)
                    case .escape:
                        if dropdownOpen {
                            dropdownOpen = false
                            return true
                        }
                        onCancel()
                        return true
                    default:
                        return false
                    }
                },
                onBeginEditing: onBeginEditing
            )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
                .frame(minWidth: 140)
                .onChange(of: text) { _, _ in
                    dropdownOpen = !filtered.isEmpty
                    activeIndex = 0
                }

            if showSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, col in
                        HStack {
                            Text(col.name)
                                .font(.callout)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == activeIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let committed = buildTextWithReplacement(col.name)
                            text = committed
                            onCommit(committed)
                        }
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 4)
                .frame(width: 180)
                .padding(.top, 2)
            }
        }
        .onClickOutside { commitOnClickOutside() }
    }

    private func commitOnClickOutside() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onCancel()
        } else {
            onCommit(text)
        }
    }

    private func handleTab(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        if filtered.count == 1 {
            tabInsertSingle(filtered[0].name)
            return true
        }
        activeIndex = clamp(reverse ? activeIndex - 1 : activeIndex + 1, filtered.count)
        return true
    }

    private func handleArrow(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        activeIndex = clamp(reverse ? activeIndex - 1 : activeIndex + 1, filtered.count)
        return true
    }

    private func clamp(_ i: Int, _ count: Int) -> Int {
        if count == 0 { return 0 }
        return min(max(i, 0), count - 1)
    }

    private func commitSelection(_ name: String) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty {
            text = name + ", "
        } else {
            parts[parts.count - 1] = name
            text = parts.joined(separator: ", ") + ", "
        }
        dropdownOpen = false
        activeIndex = 0
    }

    private func tabInsertSingle(_ name: String) {
        text = buildTextWithReplacement(name)
    }

    private func buildTextWithReplacement(_ name: String) -> String {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty {
            return name
        } else {
            parts[parts.count - 1] = name
            return parts.joined(separator: ", ")
        }
    }
}
