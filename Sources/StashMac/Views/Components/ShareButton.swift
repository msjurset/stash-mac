import SwiftUI
import AppKit

/// SwiftUI button that opens the Stash share menu anchored to
/// itself. The menu is built fresh per click by `ShareMenu` and
/// adapts to the item's type — image / url / snippet / file /
/// email each get their own action set. The native
/// `NSSharingServicePicker` is the last item as a fallback for
/// AirDrop or any registered third-party share extension.
///
/// Why a custom menu rather than the system picker as the
/// primary surface: the picker only surfaces apps that have
/// registered as share targets, which excludes Signal, the
/// Mac's primary chat path for many users. The custom menu's
/// "Image with caption" composites the photo + AI notes as a
/// single PNG on the clipboard so one paste into Signal lands
/// both the image and the caption in one go.
struct ShareButton: View {
    /// Builder rather than a stored value so the closure can
    /// re-read the latest state (edited notes, just-attached
    /// files, etc.) at the moment the user clicks.
    let item: () -> StashItem?

    var label: () -> AnyView = {
        AnyView(Label("Share", systemImage: "square.and.arrow.up"))
    }

    var body: some View {
        ShareAnchorView(itemProvider: item) {
            label()
        }
    }
}

/// NSViewRepresentable that hosts a regular AppKit `NSButton`
/// configured to look like a SwiftUI toolbar button, and pops
/// `ShareMenu.menu(for:)` anchored to that button on click.
///
/// We need an actual AppKit view because `NSMenu.popUp`
/// requires an `NSView` for positioning. A pure SwiftUI
/// `Menu` doesn't compose cleanly with our context-sensitive,
/// dynamically-built menu structure.
private struct ShareAnchorView<Content: View>: NSViewRepresentable {
    let itemProvider: () -> StashItem?
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
        context.coordinator.itemProvider = itemProvider
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.itemProvider = itemProvider
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var itemProvider: (() -> StashItem?)?

        @objc func tapped(_ sender: NSButton) {
            guard let item = itemProvider?() else {
                NSSound.beep()
                return
            }
            let menu = ShareMenu.menu(for: item)
            guard menu.numberOfItems > 0 else {
                NSSound.beep()
                return
            }
            let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }
    }
}
