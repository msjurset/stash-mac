import AppKit
import SwiftUI

/// Generates a persistent thumbnail from the item's default
/// placeholder view. Used as a final fallback for 'Generate'
/// requests so the user never sees a failure dialog, even for
/// file types macOS doesn't support.
@MainActor
enum PlaceholderGenerator {
    
    /// Generate a 512x512 snapshot of the item's placeholder.
    static func generatePlaceholder(for item: StashItem) -> NSImage? {
        let view = TypeStyledPlaceholder(item: item)
            .frame(width: 512, height: 512)
        
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage
    }
}
