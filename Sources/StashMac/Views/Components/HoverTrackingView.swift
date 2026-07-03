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

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if trackingArea == nil {
                let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect]
                let newArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
                addTrackingArea(newArea)
                self.trackingArea = newArea
            }
        }

        override func mouseMoved(with event: NSEvent) {
            cancelExit()
            let loc = self.convert(event.locationInWindow, from: nil)
            onHover?(loc)
        }

        override func mouseEntered(with event: NSEvent) {
            cancelExit()
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
