import SwiftUI
import AppKit

struct InlineTagInput: View {
    @Binding var text: String
    let allTags: [StashTag]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var activeIndex = 0
    @State private var dropdownOpen = false

    /// Current comma-separated token at the cursor (the last fragment).
    /// The word being edited is NOT excluded from suggestions — per the rule,
    /// "the word currently being edited does not count as 'used'".
    private var currentToken: String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Tags committed so far, excluding the one at the cursor.
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
                placeholder: "tag",
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
                }
            )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
                .frame(minWidth: 120)
                .onChange(of: text) { _, _ in
                    dropdownOpen = !filtered.isEmpty
                    activeIndex = 0
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
                            // Mouse click commits with trailing separator and
                            // closes the inline editor (tap-to-finish feel).
                            let committed = buildTextWithReplacement(tag.name)
                            text = committed
                            onCommit(committed)
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
        .background(ClickOutsideMonitor(onClickOutside: onCancel))
    }

    // MARK: - Key handlers

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

    // MARK: - Text mutation

    /// Replace the current (last) comma-separated token and append ", " so
    /// the user can immediately type the next tag.
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

    /// Replace the current token with `name` — no trailing separator — and
    /// keep the dropdown open so another Tab or Enter can commit.
    private func tabInsertSingle(_ name: String) {
        text = buildTextWithReplacement(name)
        // onChange will recompute filtered; activeIndex reset to 0.
    }

    /// Return `text` with the last comma-separated token replaced.
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

// MARK: - Click Outside Monitor

/// Detects mouse clicks outside the host view's bounds and calls the dismiss handler.
private struct ClickOutsideMonitor: NSViewRepresentable {
    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> ClickOutsideNSView {
        let view = ClickOutsideNSView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ nsView: ClickOutsideNSView, context: Context) {
        nsView.onClickOutside = onClickOutside
    }

    class ClickOutsideNSView: NSView {
        var onClickOutside: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                let locationInWindow = event.locationInWindow
                let locationInView = self.convert(locationInWindow, from: nil)
                if !self.bounds.contains(locationInView) {
                    DispatchQueue.main.async { self.onClickOutside?() }
                }
                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
