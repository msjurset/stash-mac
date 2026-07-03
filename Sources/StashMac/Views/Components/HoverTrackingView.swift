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

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea = trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect]
            let newArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(newArea)
            self.trackingArea = newArea
        }

        override func mouseMoved(with event: NSEvent) {
            let loc = self.convert(event.locationInWindow, from: nil)
            onHover?(loc)
        }

        override func mouseEntered(with event: NSEvent) {
            let loc = self.convert(event.locationInWindow, from: nil)
            onHover?(loc)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(nil)
        }
    }
}
