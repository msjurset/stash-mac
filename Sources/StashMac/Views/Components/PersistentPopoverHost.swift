import AppKit
import SwiftUI

/// Wraps `NSPopover` so a SwiftUI view can host a popover that stays
/// open while the user interacts with sibling views in the same
/// window. SwiftUI's built-in `.popover` uses `behavior = .transient`,
/// which dismisses on any focus change — clicking back into the
/// originating field closes it. Our regex cheatsheet wants the
/// opposite: stay open while typing in the search field, dismiss
/// when the user clicks outside the search panel entirely.
///
/// We get that with `behavior = .semitransient`: the popover stays
/// alive as long as its source's window remains key. Switching apps,
/// closing the panel, or clicking outside the panel all dismiss it
/// cleanly.
struct PersistentPopoverHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// Edge of the source view the popover should anchor to.
    /// `.minY` = below source, `.maxY` = above, `.minX` = left, `.maxX` = right.
    let preferredEdge: NSRectEdge
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        // A bare NSView used purely as the anchor for NSPopover's
        // `show(relativeTo:of:)`. Don't override autoresizing —
        // setting `translatesAutoresizingMaskIntoConstraints = false`
        // without adding constraints leaves the host with no
        // intrinsic size, which SwiftUI's layout system propagates as
        // unbounded height through any `.background(...)` use of this
        // representable. We want this view to follow the size of
        // whatever it's placed behind.
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if isPresented {
            if let popover = coordinator.popover {
                // Already up — refresh content (lets the SwiftUI
                // closure pick up the latest @State references).
                popover.contentViewController = NSHostingController(rootView: content())
            } else {
                // Defer until the next runloop tick so the source
                // view has stable bounds when AppKit positions the
                // popover. Showing during update() while geometry is
                // still settling produces wrong arrow placement.
                DispatchQueue.main.async {
                    guard self.isPresented else { return }
                    let popover = NSPopover()
                    popover.behavior = .semitransient
                    popover.contentViewController = NSHostingController(rootView: self.content())
                    popover.delegate = coordinator
                    coordinator.popover = popover
                    popover.show(
                        relativeTo: nsView.bounds,
                        of: nsView,
                        preferredEdge: self.preferredEdge
                    )
                }
            }
        } else if let popover = coordinator.popover {
            popover.performClose(nil)
            coordinator.popover = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: PersistentPopoverHost
        var popover: NSPopover?

        init(parent: PersistentPopoverHost) {
            self.parent = parent
        }

        nonisolated func popoverDidClose(_ notification: Notification) {
            // User dismissed (clicked outside the panel, switched
            // apps, etc.) — sync the binding so the parent view
            // doesn't think the popover is still showing.
            Task { @MainActor in
                self.parent.isPresented = false
                self.popover = nil
            }
        }
    }
}
