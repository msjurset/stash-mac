import SwiftUI
import AppKit

/// Single-line inline text editor for view-mode → edit-mode transitions.
/// Encapsulates the project's "always-on-X-inside, click-off-to-save"
/// convention so every inline-edit surface looks and behaves the same.
///
/// Behavior:
///   - Trailing "X" button appears inside the field whenever the buffer
///     isn't empty. Click clears the buffer; field stays focused.
///   - Click-off / focus loss → `onCommit` fires, edit dismisses.
///   - Enter → `onCommit`.
///   - Escape → `onCancel`. Caller decides whether to revert state.
///
/// **Click-off detection.** NSTextField only fires
/// `controlTextDidEndEditing` when another view bids for first responder.
/// Plain SwiftUI labels and the surrounding ScrollView don't, so without
/// help the field stays focused forever when the user clicks empty space.
/// We install a local NSEvent mouse-down monitor for the field's
/// lifetime; any click outside our SwiftUI bounds (X button included)
/// makes the window resign first responder, which fires the field's
/// `onEndEditing` and runs `onCommit`. The X button is INSIDE our bounds
/// so clicking it clears the text without dismissing.
struct InlineEditField: View {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .preferredFont(forTextStyle: .body)
    var alignment: NSTextAlignment = .left
    /// Whether the field should grab first responder when it appears.
    /// Default is `true` so the click-off-saves contract works even
    /// when the parent flipped into edit mode via a button rather
    /// than a click directly inside the field — without focus, the
    /// click-outside monitor's `makeFirstResponder(nil)` has nothing
    /// to resign and `controlTextDidEndEditing` never fires.
    var autoFocus: Bool = true
    /// Called when the field loses focus or the user presses Enter.
    var onCommit: () -> Void
    /// Called when the user presses Escape.
    var onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            FilterField(
                placeholder: placeholder,
                text: $text,
                font: font,
                alignment: alignment,
                autoFocus: autoFocus,
                onSubmit: onCommit,
                onKey: { key in
                    if key == .escape {
                        onCancel()
                        return true
                    }
                    return false
                },
                onEndEditing: onCommit
            )
            .padding(.leading, 8)
            // Reserve the trailing slot for the X button. The NSTextField
            // still draws across its full width, but the SwiftUI-level
            // padding shifts the visual chrome (focus ring / background)
            // so the X overlays the field's edge cleanly.
            .padding(.trailing, 28)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            )

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("Clear")
            }
        }
        .background(ClickOutsideMonitorView())
    }
}

/// A background view that installs a local NSEvent mouse-down monitor.
/// If a click happens outside the view's bounds, it resigns the first responder.
private struct ClickOutsideMonitorView: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView {
        return MonitorView()
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {}

    final class MonitorView: NSView {
        nonisolated(unsafe) private var clickOutsideMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if self.window != nil {
                setupMonitor()
            } else {
                teardownMonitor()
            }
        }

        private func setupMonitor() {
            guard self.window != nil, clickOutsideMonitor == nil else { return }
            clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self else { return event }
                guard event.clickCount == 1 else { return event }
                // Convert self.bounds to window coordinates:
                let frameInWindow = self.convert(self.bounds, to: nil)
                if !frameInWindow.contains(event.locationInWindow) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let w = self.window else { return }
                        w.makeFirstResponder(nil)
                    }
                }
                return event
            }
        }

        private func teardownMonitor() {
            if let monitor = clickOutsideMonitor {
                NSEvent.removeMonitor(monitor)
                clickOutsideMonitor = nil
            }
        }

        override func removeFromSuperview() {
            teardownMonitor()
            super.removeFromSuperview()
        }

        deinit {
            if let monitor = clickOutsideMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
