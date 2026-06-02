import SwiftUI

/// Modifier that tracks a view's global frame and reports it to the `HelpOverlayModel`.
struct HelpAnchorModifier: ViewModifier {
    let id: HelpAnchorID
    @Environment(HelpOverlayModel.self) private var model
    
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("window"))
            } action: { newValue in
                model.updateFrame(newValue, for: id)
            }
            .onDisappear {
                model.updateFrame(.zero, for: id)
            }
    }
}

extension View {
    /// Registers this view as a target for the interactive Help Overlay.
    func helpAnchor(_ id: HelpAnchorID) -> some View {
        modifier(HelpAnchorModifier(id: id))
    }
}
