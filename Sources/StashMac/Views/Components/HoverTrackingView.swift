import SwiftUI

struct HoverTrackingView: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onHover = onHover
    }

    class TrackingNSView: NSView {
        var onHover: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var exitWorkItem: DispatchWorkItem?
        private var lastHoverTime: TimeInterval = 0

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow]
            let newArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(newArea)
            self.trackingArea = newArea
        }

        override func mouseMoved(with event: NSEvent) {
            cancelExit()
            let now = CACurrentMediaTime()
            if now - lastHoverTime < 0.016 { return }
            lastHoverTime = now
            let loc = self.convert(event.locationInWindow, from: nil)
            onHover?(loc)
        }

        override func mouseEntered(with event: NSEvent) {
            cancelExit()
            let now = CACurrentMediaTime()
            if now - lastHoverTime < 0.016 { return }
            lastHoverTime = now
            let loc = self.convert(event.locationInWindow, from: nil)
            onHover?(loc)
        }

        override func mouseExited(with event: NSEvent) {
            let item = DispatchWorkItem { [weak self] in
                self?.onHover?(nil)
            }
            exitWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }
        
        private func cancelExit() {
            exitWorkItem?.cancel()
            exitWorkItem = nil
        }
    }
}
