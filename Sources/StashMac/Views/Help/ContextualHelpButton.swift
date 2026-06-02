import SwiftUI

/// A small button that opens the help window to a specific topic.
struct ContextualHelpButton: View {
    let topic: HelpTopic
    var isToolbarItem: Bool = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "help", value: topic)
        } label: {
            if isToolbarItem {
                Image(systemName: "questionmark.circle")
            } else {
                Label("Help", systemImage: "questionmark.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .help("View help for this section")
        .modifier(HelpButtonStyleModifier(isToolbarItem: isToolbarItem))
    }
}

private struct HelpButtonStyleModifier: ViewModifier {
    let isToolbarItem: Bool
    func body(content: Content) -> some View {
        if isToolbarItem {
            content
        } else {
            content
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
        }
    }
}
