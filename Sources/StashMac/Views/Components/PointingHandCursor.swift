import SwiftUI
import AppKit

/// `.pointingHandCursor()` — show the macOS pointing-hand cursor
/// while the mouse is over this view. Used on row-style buttons
/// whose visual is just text (no obvious button chrome) so the user
/// gets a clear "this is clickable" affordance.
///
/// macOS doesn't provide a separate pressed-state cursor; the click
/// feedback comes from the button's own visual state (background
/// highlight, scale). That's the native pattern and we don't try to
/// fake an alternate cursor on mouse-down.
extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func resizeLeftRightCursor() -> some View {
        modifier(ResizeLeftRightCursorModifier())
    }
}

private struct ResizeLeftRightCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
