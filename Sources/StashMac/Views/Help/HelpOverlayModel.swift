import SwiftUI
import Observation

/// Central state for the interactive help overlay.
@Observable
@MainActor
final class HelpOverlayModel {
    /// Whether the help overlay (X-Ray mode) is currently visible.
    var isActive = false {
        didSet {
            if !isActive {
                hoveredAnchor = nil
            }
        }
    }
    
    /// The anchor currently being hovered, if any.
    var hoveredAnchor: HelpAnchorID? = nil
    
    /// The anchor currently selected (showing a popover).
    var selectedAnchor: HelpAnchorID? = nil
    
    /// Global frames for all registered anchors.
    var frames: [HelpAnchorID: CGRect] = [:]
    
    /// Updates the frame for a specific anchor.
    func updateFrame(_ frame: CGRect, for id: HelpAnchorID) {
        frames[id] = frame
    }
}
