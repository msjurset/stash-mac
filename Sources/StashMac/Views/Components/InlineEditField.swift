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

    /// Reference-typed holder for our SwiftUI bounds in window
    /// coordinates. The frame reader writes here synchronously from
    /// `viewDidMoveToWindow` / `layout()`, so the click-outside monitor
    /// always reads the latest value at click time — no async lag, no
    /// race with fast click-offs that didn't make an edit.
    @State private var frameHolder = FieldFrameHolder()
    @State private var clickOutsideMonitor: Any?

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
        .background(WindowFrameReader(holder: frameHolder))
        .onAppear { installClickOutsideMonitor() }
        .onDisappear { removeClickOutsideMonitor() }
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        // Capture the holder reference once; the closure reads its
        // mutable `frame` property at click time, so layout updates that
        // happen between install and click are picked up.
        let holder = frameHolder
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window else { return event }
            let frame = holder.frame
            // Frame not yet known (probe view hasn't laid out). The
            // ProbeView's viewDidMoveToWindow runs synchronously when
            // the view enters the window, so this should already be
            // populated by the time any click reaches us. If somehow
            // it's still zero, skip — better than dismissing on the
            // user's first click into the field.
            guard frame != .zero else { return event }

            if !frame.contains(event.locationInWindow) {
                // Defer to the next tick so the click reaches its real
                // target (button, row selection, …) first. Resigning
                // first responder fires the field editor's
                // textDidEndEditing → onEndEditing → onCommit.
                DispatchQueue.main.async {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}

/// Reference-type frame holder. Keeping the frame in a class instead of
/// `@State<NSRect>` lets `WindowFrameReader.ProbeView` write to it
/// synchronously from layout callbacks (no SwiftUI state mutation), and
/// lets the click-outside monitor read the live value via the captured
/// reference.
private final class FieldFrameHolder {
    var frame: NSRect = .zero
}

/// NSViewRepresentable that writes its frame (in window coordinates) to
/// a holder synchronously from layout callbacks. The holder is a class,
/// so we can mutate it from layout without violating SwiftUI's "no state
/// updates during view update" invariant — we're updating a class
/// property, not a SwiftUI @State.
private struct WindowFrameReader: NSViewRepresentable {
    let holder: FieldFrameHolder

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.holder = holder
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.holder = holder
    }

    final class ProbeView: NSView {
        weak var holder: FieldFrameHolder?

        override func layout() {
            super.layout()
            reportFrame()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override var frame: NSRect {
            didSet { reportFrame() }
        }

        private func reportFrame() {
            // Convert from superview coords (where self.frame lives) to
            // window coords (`to: nil`). The click-outside monitor reads
            // this and compares against NSEvent.locationInWindow.
            guard let inWindow = superview?.convert(self.frame, to: nil) else { return }
            holder?.frame = inWindow
        }
    }
}
