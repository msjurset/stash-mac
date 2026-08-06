import SwiftUI
import AppKit

/// NSEvent-level click handler that fires `onSingleClick` and
/// `onDoubleClick` *before* AppKit's text view / SwiftUI gestures
/// can claim them. Drag gestures pass through untouched.
///
/// Use this when:
///   - The view contains selectable text whose tracking loop
///     swallows mouseUp/mouseDragged before SwiftUI's gesture system
///     sees them.
///   - Double-click would cascade into a sibling's single-click
///     gesture after the layout shifts (e.g. the title in
///     `ItemDetailView` flipping to an edit field opened the image
///     preview's tap handler).
///
/// Logic:
///   - `mouseDown` (clickCount 1): remember the location, schedule
///     `onSingleClick` via a 300ms delay (so a follow-up double can
///     cancel it). At fire time, sample the current cursor position;
///     if it moved past the drag threshold, treat as a drag-select
///     and skip.
///   - `mouseDragged` past threshold: cancel the pending single.
///   - `mouseDown` (clickCount 2): cancel pending single, fire
///     `onDoubleClick`, and consume the event so AppKit / SwiftUI
///     don't propagate it.
///
/// Mount as `.background(ClickCatcher(...))` on whatever view should
/// receive the clicks — the catcher's frame matches the host view.
struct ClickCatcher: NSViewRepresentable {
    var onSingleClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> CatcherView {
        CatcherView(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    /// Without this, NSViewRepresentable defaults to intrinsicContentSize
    /// (zero for a bare NSView) — `bounds` stays at .zero, and the
    /// bounds-contains check in the event monitor always fails.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CatcherView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }

    final class CatcherView: NSView {
        var onSingleClick: () -> Void
        var onDoubleClick: () -> Void
        private var monitor: Any?
        private var pendingSingle: DispatchWorkItem?
        private var downLocation: NSPoint?
        private var downInside = false
        private var didDrag = false
        private static let dragThresholdSq: CGFloat = 16

        init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Hit-transparent. The local NSEvent monitor receives events
        /// independently of hit-testing, so we don't need to claim the
        /// region — and claiming it can swallow clicks intended for
        /// SwiftUI gestures or AppKit text selection on the host view.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return self.process(event)
            }
        }

        private func process(_ event: NSEvent) -> NSEvent? {
            let pointInView = convert(event.locationInWindow, from: nil)
            let inBounds = bounds.contains(pointInView)

            switch event.type {
            case .leftMouseDown:
                if event.clickCount >= 2 && inBounds {
                    if isPointOnCharacter(event) {
                        downInside = false
                        pendingSingle?.cancel()
                        pendingSingle = nil
                        didDrag = false
                        return event
                    } else if event.clickCount == 2 {
                        downInside = true
                        pendingSingle?.cancel()
                        pendingSingle = nil
                        didDrag = false
                        return nil
                    }
                }
                if event.clickCount == 1 && inBounds {
                    downInside = true
                    didDrag = false
                    downLocation = event.locationInWindow
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, let window = self.window, let down = self.downLocation else { return }
                        let current = window.mouseLocationOutsideOfEventStream
                        let dx = current.x - down.x
                        let dy = current.y - down.y
                        if dx * dx + dy * dy > Self.dragThresholdSq {
                            return
                        }
                        self.onSingleClick()
                    }
                    pendingSingle?.cancel()
                    pendingSingle = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                } else {
                    downInside = false
                }
                return event

            case .leftMouseDragged:
                if downInside, let down = downLocation {
                    let dx = event.locationInWindow.x - down.x
                    let dy = event.locationInWindow.y - down.y
                    if dx * dx + dy * dy > Self.dragThresholdSq {
                        didDrag = true
                        pendingSingle?.cancel()
                        pendingSingle = nil
                    }
                }
                return event

            case .leftMouseUp:
                if event.clickCount == 2 && downInside {
                    downInside = false
                    DispatchQueue.main.async { self.onDoubleClick() }
                    return nil
                }
                downInside = false
                return event

            default:
                return event
            }
        }

        private func isPointOnCharacter(_ event: NSEvent) -> Bool {
            guard let hostView = self.superview else { return false }
            return checkCharacterInViewTree(hostView, locationInWindow: event.locationInWindow)
        }

        private func checkCharacterInViewTree(_ view: NSView, locationInWindow: NSPoint) -> Bool {
            if let tv = view as? NSTextView {
                let pt = tv.convert(locationInWindow, from: nil)
                if tv.bounds.contains(pt) {
                    if isPointOnGlyph(in: tv, point: pt) {
                        return true
                    }
                }
            }
            for sub in view.subviews {
                if checkCharacterInViewTree(sub, locationInWindow: locationInWindow) {
                    return true
                }
            }
            return false
        }

        private func isPointOnGlyph(in tv: NSTextView, point: NSPoint) -> Bool {
            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer else { return false }

            let origin = tv.textContainerOrigin
            let ptInContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

            let glyphIndex = layoutManager.glyphIndex(for: ptInContainer, in: textContainer)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return false }

            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            return rect.insetBy(dx: -1, dy: -1).contains(ptInContainer)
        }
    }
}
