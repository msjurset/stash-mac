import SwiftUI
import AppKit

/// Selectable URL text that opens in the browser on click but still
/// supports drag-to-select for copy-paste.
///
/// Implementation history (relevant because each previous attempt
/// regressed in a different way and the next person will be tempted to
/// undo the current shape):
///
///   1. SwiftUI `Text + .onTapGesture + .textSelection(.enabled)` — tap
///      gesture never fired because NSTextView's selection-tracking
///      loop swallows mouse-up.
///   2. `Text(AttributedString)` with `.link` — renders blue but is
///      inert on macOS 26 (Tahoe); cursor doesn't change, click does
///      nothing, selection doesn't work either.
///   3. `NSTextView` inside `NSScrollView` — collapsed to zero height
///      because the scroll view doesn't propagate the inner text
///      view's intrinsic content size to SwiftUI.
///
/// Current shape: a custom `NSTextField` (selectable, non-editable)
/// with an `NSAttributedString` value. NSTextField has reliable cell-
/// based intrinsic sizing inside SwiftUI, and its first `mouseDown`
/// fires *before* the field editor is engaged — that's the hook used
/// to distinguish click from drag-select. After click the field has
/// focus and the field editor handles selection normally.
struct ClickableURLText: NSViewRepresentable {
    let urlString: String

    func makeNSView(context: Context) -> LinkField {
        let field = LinkField()
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.allowsEditingTextAttributes = true
        field.urlString = urlString
        field.attributedStringValue = LinkField.attributed(for: urlString)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: LinkField, context: Context) {
        if field.urlString != urlString {
            field.urlString = urlString
            field.attributedStringValue = LinkField.attributed(for: urlString)
        }
    }

    @MainActor
    final class LinkField: NSTextField {
        var urlString: String = ""

        /// Mouse-up is treated as a click if the cursor moved less than
        /// this many points between mouse-down and the deferred check.
        private let dragThreshold: CGFloat = 4
        /// NSTextView's selection-tracking loop blocks mouse-up
        /// delivery, so we sample the cursor position after a short
        /// delay instead of waiting for mouse-up. Long enough that
        /// selection drags have started moving; short enough that a
        /// single click feels instant.
        private let clickDelay: TimeInterval = 0.16

        static func attributed(for urlString: String) -> NSAttributedString {
            let attr = NSMutableAttributedString(
                string: urlString,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.systemBlue,
                ]
            )
            return attr
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }

        /// NSTextFieldCell installs an I-beam cursor for selectable
        /// text via its own resetCursorRects. To win the override we
        /// register a tracking area with `.cursorUpdate +
        /// .mouseEnteredAndExited + .inVisibleRect + .activeAlways`
        /// and set the pointing-hand cursor from each callback. Belt
        /// and suspenders — different macOS revs route the override
        /// signal through different events; we cover all three.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas
                .filter { $0.owner === self }
                .forEach { removeTrackingArea($0) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [
                    .cursorUpdate,
                    .mouseEnteredAndExited,
                    .inVisibleRect,
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            let startLocation = NSEvent.mouseLocation
            DispatchQueue.main.asyncAfter(deadline: .now() + clickDelay) { [weak self] in
                guard let self else { return }
                let now = NSEvent.mouseLocation
                let distance = hypot(now.x - startLocation.x, now.y - startLocation.y)
                guard distance < self.dragThreshold else { return }
                if let url = URL(string: self.urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            super.mouseDown(with: event)
        }
    }
}
