import SwiftUI
import AppKit

/// Comma-separated tag input with autocomplete on the current (last) token.
/// Visual styling matches `StashField` (rounded border, focus tint) so it
/// slots into form layouts.
///
/// Add-new-value field. Pre-highlight rule is **conditional**:
/// - When the current token is non-empty (user is actively typing a tag),
///   `activeIndex` is `0` — the top filtered match is pre-highlighted so
///   Enter commits the obvious next tag.
/// - When the current token is empty (e.g. just after a `, ` separator,
///   the dropdown is showing all candidates), `activeIndex` is `-1` —
///   no pre-highlight, so Enter means "done editing tags" rather than
///   "commit whichever tag happens to be on top of the list".
///
/// Keyboard model:
/// - Tab / Shift-Tab: open dropdown if closed; advance highlight; with a
///   single match and the highlight on it, insert the token without a
///   trailing separator.
/// - Arrow Down / Up: open dropdown; move highlight, including back to -1
///   ("no selection") so Enter can be used to finish editing.
/// - Enter with highlight (`activeIndex >= 0`): commit the highlighted tag,
///   append `, ` so the user can keep typing more tags.
/// - Enter without highlight: "done editing" — trim any trailing comma /
///   whitespace and resign first responder so focus moves on naturally.
/// - Escape with dropdown open: dismiss the dropdown. Field unchanged.
struct MultiTagField: View {
    @Binding var text: String
    let allTags: [StashTag]
    var placeholder: String = "Comma-separated"

    /// -1 means "no row highlighted". Auto-pop on typing should not
    /// pre-highlight; only explicit Tab / arrow advances it to 0+.
    @State private var activeIndex = -1
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
                    case .enter:     return handleEnter()
                    case .escape:
                        if dropdownOpen {
                            dropdownOpen = false
                            activeIndex = -1
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
                    activeIndex = defaultHighlightIndex()
                },
                onEndEditing: {
                    isFocused = false
                    dropdownOpen = false
                    activeIndex = -1
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
                // Pre-highlight only while the user is actively typing a
                // tag (current token non-empty). With an empty token —
                // i.e. sitting on the trailing `, ` after a previous
                // commit — keep activeIndex at -1 so Enter means "done".
                activeIndex = defaultHighlightIndex()
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

    /// Default highlight position when the dropdown auto-opens (typing,
    /// focus arrival, text mutation). Returns 0 when the user is mid-tag
    /// (current token has characters), -1 otherwise.
    private func defaultHighlightIndex() -> Int {
        if filtered.isEmpty { return -1 }
        return currentToken.isEmpty ? -1 : 0
    }

    private func handleTab(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        // Single-match shortcut: when there's exactly one filtered tag and
        // it's the highlighted one, Tab inserts it (no trailing separator,
        // dropdown stays open so the user can keep going).
        if filtered.count == 1 && activeIndex == 0 {
            tabInsertSingle(filtered[0].name)
            return true
        }
        // Advance the highlight. From -1 the first Tab goes to 0 (forward)
        // or last (reverse).
        if reverse {
            activeIndex = activeIndex < 0 ? filtered.count - 1 : max(0, activeIndex - 1)
        } else {
            activeIndex = activeIndex < 0 ? 0 : clamp(activeIndex + 1)
        }
        return true
    }

    private func handleArrow(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        // Arrows can wrap back through -1 ("no selection"), so the user
        // can navigate INTO highlight, then back OUT to the no-highlight
        // state where Enter means "done".
        if reverse {
            if activeIndex < 0 { activeIndex = filtered.count - 1 }
            else if activeIndex == 0 { activeIndex = -1 }
            else { activeIndex -= 1 }
        } else {
            if activeIndex < 0 { activeIndex = 0 }
            else if activeIndex >= filtered.count - 1 { activeIndex = -1 }
            else { activeIndex += 1 }
        }
        return true
    }

    /// Enter behavior:
    /// - With a highlighted suggestion → commit it, append `, ` so the
    ///   user can keep adding more tags. Stays in the field.
    /// - Without a highlight → "done editing": trim any trailing
    ///   comma/whitespace and resign first responder so focus moves on.
    ///   This is what users mean when they press Enter after building up
    ///   a tag list and the dropdown happens to be showing all candidates
    ///   because the current token is empty.
    private func handleEnter() -> Bool {
        if showSuggestions && activeIndex >= 0 && activeIndex < filtered.count {
            commitSelection(filtered[activeIndex].name)
            return true
        }
        // Trim trailing whitespace and commas in any combination.
        var trimmed = text
        while let last = trimmed.last, last == "," || last == " " || last == "\t" {
            trimmed.removeLast()
        }
        if trimmed != text {
            text = trimmed
        }
        dropdownOpen = false
        activeIndex = -1
        // Defer one tick so SwiftUI / FilterField finish processing the
        // Enter key before we resign — otherwise the key may be re-emitted
        // as a beep when no first responder accepts it.
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
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
        activeIndex = -1
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
