import SwiftUI
import AppKit

struct InlineTagInput: View {
    @Binding var text: String
    let allTags: [StashTag]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var showSuggestions = false
    @State private var activeIndex = -1
    @FocusState private var isFocused: Bool

    /// The current token being typed (after the last comma).
    private var currentToken: String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Tags already entered before the current token.
    private var enteredTags: Set<String> {
        let parts = text.split(separator: ",").dropLast(text.hasSuffix(",") ? 0 : 1)
        return Set(parts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    private var filtered: [StashTag] {
        let query = currentToken
        if query.isEmpty { return [] }
        return allTags
            .filter { tag in
                let lower = tag.name.lowercased()
                return (query.isEmpty || lower.contains(query)) && !enteredTags.contains(lower)
            }
            .prefix(6)
            .map { $0 }
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
                .frame(minWidth: 120)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onChange(of: text) { _, _ in
                    showSuggestions = !filtered.isEmpty
                    activeIndex = -1
                }
                .onSubmit {
                    if activeIndex >= 0, activeIndex < filtered.count {
                        // Accept suggestion into the field, don't commit yet
                        replaceCurrentToken(with: filtered[activeIndex].name)
                        activeIndex = -1
                        showSuggestions = false
                    } else {
                        // No active suggestion — commit the full text.
                        // Capture the value now since @Binding reads can be stale.
                        let current = text
                        onCommit(current)
                    }
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .onKeyPress(.tab) {
                    if !filtered.isEmpty {
                        activeIndex = activeIndex < 0 ? 0 : min(activeIndex + 1, filtered.count - 1)
                        replaceCurrentToken(with: filtered[activeIndex].name)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    if !filtered.isEmpty {
                        activeIndex = min(activeIndex + 1, filtered.count - 1)
                        replaceCurrentToken(with: filtered[activeIndex].name)
                    }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if !filtered.isEmpty {
                        activeIndex = max(activeIndex - 1, 0)
                        replaceCurrentToken(with: filtered[activeIndex].name)
                    }
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

    /// Returns the text with the current (last) token replaced, without mutating the binding.
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

    /// Replace the current (last) comma-separated token in the binding.
    private func replaceCurrentToken(with name: String) {
        text = buildTextWithReplacement(name)
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
                guard let self, let window = self.window else { return event }
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
