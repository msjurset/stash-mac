import SwiftUI

/// Comma-separated tag input with autocomplete on the current (last) token.
/// Visual styling matches `StashField` (rounded border, focus tint) so it
/// slots into form layouts.
///
/// Keyboard model follows the global auto-suggest rule:
/// - Tab / Shift-Tab: open dropdown → advance highlight → (single-item) insert
///   the token without a trailing separator.
/// - Arrow Down/Up: open dropdown → move highlight (no field mutation).
/// - Enter (dropdown visible): commit highlighted tag, append `, ` so the
///   user can keep typing.
/// - Enter (no dropdown): not consumed — falls through to the form's
///   default action.
/// - Escape (dropdown visible): dismiss. Otherwise not consumed.
struct MultiTagField: View {
    @Binding var text: String
    let allTags: [StashTag]
    var placeholder: String = "Comma-separated"

    @State private var activeIndex = 0
    @State private var dropdownOpen = false
    @State private var isFocused = false

    private var currentToken: String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var enteredTags: Set<String> {
        let parts = text.split(separator: ",").dropLast(text.hasSuffix(",") ? 0 : 1)
        return Set(parts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    private var filtered: [StashTag] {
        let query = currentToken
        return allTags
            .filter { tag in
                let lower = tag.name.lowercased()
                return (query.isEmpty || lower.contains(query)) && !enteredTags.contains(lower)
            }
            .prefix(6)
            .map { $0 }
    }

    private var showSuggestions: Bool { dropdownOpen && !filtered.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterField(
                placeholder: placeholder,
                text: $text,
                onKey: { key in
                    switch key {
                    case .tab:       return handleTab(reverse: false)
                    case .shiftTab:  return handleTab(reverse: true)
                    case .arrowDown: return handleArrow(reverse: false)
                    case .arrowUp:   return handleArrow(reverse: true)
                    case .enter:
                        if showSuggestions, activeIndex < filtered.count {
                            commitSelection(filtered[activeIndex].name)
                            return true
                        }
                        return false
                    case .escape:
                        if dropdownOpen {
                            dropdownOpen = false
                            return true
                        }
                        return false
                    default:
                        return false
                    }
                },
                onBeginEditing: {
                    isFocused = true
                    dropdownOpen = !filtered.isEmpty
                },
                onEndEditing: {
                    isFocused = false
                    dropdownOpen = false
                }
            )
            .padding(8)
            .background(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .onChange(of: text) { _, _ in
                dropdownOpen = !filtered.isEmpty
                activeIndex = 0
            }
            .animation(.easeInOut(duration: 0.15), value: isFocused)

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
                            commitSelection(tag.name)
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
        activeIndex = clamp(reverse ? activeIndex - 1 : activeIndex + 1)
        return true
    }

    private func handleArrow(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        activeIndex = clamp(reverse ? activeIndex - 1 : activeIndex + 1)
        return true
    }

    /// Replace the current comma-separated fragment with `name` and append
    /// `, ` so the user can keep typing.
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

    /// Single-match Tab insertion — no trailing separator, dropdown stays open.
    private func tabInsertSingle(_ name: String) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty {
            text = name
        } else {
            parts[parts.count - 1] = name
            text = parts.joined(separator: ", ")
        }
    }

    private func clamp(_ i: Int) -> Int {
        let count = filtered.count
        if count == 0 { return 0 }
        return min(max(i, 0), count - 1)
    }
}
