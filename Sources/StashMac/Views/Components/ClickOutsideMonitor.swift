import SwiftUI
import AppKit

/// A ViewModifier that detects mouse clicks outside the modified view's bounds
/// and triggers a callback. Useful for inline editing fields that should
/// commit or dismiss on focus loss / click-away.
struct ClickOutsideMonitor: ViewModifier {
    let onClickOutside: () -> Void

    func body(content: Content) -> some View {
        content.background(ClickOutsideMonitorInternal(onClickOutside: onClickOutside))
    }
}

extension View {
    /// Detects mouse clicks outside this view's bounds and calls `action`.
    func onClickOutside(perform action: @escaping () -> Void) -> some View {
        self.modifier(ClickOutsideMonitor(onClickOutside: action))
    }
}

private struct ClickOutsideMonitorInternal: NSViewRepresentable {
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
                    // Use async to avoid potential UI state mutation during event processing
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
