import SwiftUI
import AppKit

/// SwiftUI button that opens the macOS Share Sheet
/// (`NSSharingServicePicker`) anchored to itself. Accepts the
/// heterogeneous `[Any]` payload that `SharePayload.build(...)`
/// produces — file URLs, link URLs, and text mixed freely.
///
/// SwiftUI's `ShareLink` is too narrow for our case (single
/// `Transferable` type per call), so we drop down to AppKit's
/// `NSSharingServicePicker` and wrap it in a small representable.
struct ShareButton: View {
    /// Builder rather than a stored array so the items closure
    /// can re-read the latest state (selection, edited tags, etc.)
    /// at the moment the user clicks.
    let items: () -> [Any]

    var label: () -> AnyView = {
        AnyView(Label("Share", systemImage: "square.and.arrow.up"))
    }

    var body: some View {
        ShareAnchorView(items: items) {
            label()
        }
    }
}

/// NSViewRepresentable that hosts a regular AppKit `NSButton`
/// configured to look like a SwiftUI toolbar button, and shows
/// `NSSharingServicePicker` anchored to that button on click.
///
/// We need an actual AppKit view because `NSSharingServicePicker.show`
/// requires an `NSView` + frame for positioning. A pure SwiftUI
/// `Button` doesn't give us a stable AppKit anchor.
private struct ShareAnchorView<Content: View>: NSViewRepresentable {
    let items: () -> [Any]
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Share"
        button.target = context.coordinator
        button.action = #selector(Coordinator.tapped(_:))
        context.coordinator.itemsProvider = items
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.itemsProvider = items
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var itemsProvider: (() -> [Any])?

        @objc func tapped(_ sender: NSButton) {
            let items = itemsProvider?() ?? []
            guard !items.isEmpty else {
                NSSound.beep()
                return
            }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
