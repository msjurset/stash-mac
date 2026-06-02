import SwiftUI

/// The full-screen interactive help overlay that darkens the app and allows
/// clicking on UI elements to see contextual help.
struct HelpOverlayView: View {
    @Environment(HelpOverlayModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let visibleAnchors = HelpAnchorID.allCases.filter { id in
                guard let frame = model.frames[id] else { return false }
                return !frame.isEmpty && 
                       frame.intersects(CGRect(origin: .zero, size: screenSize))
            }
            
            ZStack {
                // 1. Darkened background with spotlight punch-out
                Color.black.opacity(0.8)
                    .mask {
                        spotlightMask(size: screenSize, visibleAnchors: visibleAnchors)
                    }
                    .ignoresSafeArea()
                    .contentShape(Rectangle()) // Catch all clicks
                    .onTapGesture {
                        handleBackgroundTap()
                    }
                
                // 2. Glow layer for hovered/selected elements
                glowLayer(visibleAnchors: visibleAnchors)
                
                // 3. Interactive hit areas for anchors
                // These MUST be at the top level (below the popover) to catch mouse events
                ForEach(visibleAnchors, id: \.self) { id in
                    if let frame = model.frames[id] {
                        interactiveArea(for: id, frame: frame)
                    }
                }
                
                // 4. Popover layer
                if let selectedId = model.selectedAnchor, 
                   let frame = model.frames[selectedId] {
                    HelpPopoverView(id: selectedId, anchorFrame: frame, screenSize: screenSize)
                        .transition(.scale(0.95).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea(.all)
        .transition(.opacity)
        .onAppear {
            model.hoveredAnchor = nil
            model.selectedAnchor = nil
            HelpCursor.push()
        }
        .onDisappear {
            NSCursor.pop()
        }
    }
    
    private func handleBackgroundTap() {
        if model.selectedAnchor != nil {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                model.selectedAnchor = nil
            }
        } else {
            withAnimation {
                model.isActive = false
            }
        }
    }
    
    /// Creates a mask that punches a hole for the currently hovered or selected item
    private func spotlightMask(size: CGSize, visibleAnchors: [HelpAnchorID]) -> some View {
        Canvas { context, size in
            // Start with a full black fill (opaque in the mask)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            
            // Punch holes for hovered or selected anchors
            for id in visibleAnchors {
                let isHovered = model.hoveredAnchor == id
                let isSelected = model.selectedAnchor == id
                
                if (isHovered || isSelected), let frame = model.frames[id] {
                    context.blendMode = .destinationOut
                    let rect = frame.insetBy(dx: -4, dy: -4)
                    context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black))
                }
            }
        }
    }
    
    private func glowLayer(visibleAnchors: [HelpAnchorID]) -> some View {
        ForEach(visibleAnchors, id: \.self) { id in
            if let frame = model.frames[id] {
                let isHovered = model.hoveredAnchor == id
                let isSelected = model.selectedAnchor == id
                
                if isHovered || isSelected {
                    let rect = frame.insetBy(dx: -4, dy: -4)
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .shadow(color: Color.accentColor, radius: 10)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }
    
    private func interactiveArea(for id: HelpAnchorID, frame: CGRect) -> some View {
        // Invisible hit area that covers the underlying control
        // Slightly higher opacity to ensure hit-testing is reliable
        Color.white.opacity(0.005)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.hoveredAnchor = hovering ? id : nil
                }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    if model.selectedAnchor == id {
                        // Clicking the same element again toggles it off
                        model.selectedAnchor = nil
                    } else {
                        model.selectedAnchor = id
                    }
                }
            }
    }
    
    private struct HelpCursor {
        static func push() {
            let size = NSSize(width: 24, height: 24)
            let image = NSImage(size: size, flipped: false) { rect in
                if let symbol = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: "Help") {
                    NSColor.white.set()
                    symbol.draw(in: rect)
                    return true
                }
                return false
            }
            
            let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
            cursor.push()
        }
        
        static func pop() {
            NSCursor.pop()
        }
    }
}

/// The contextual help popover that appears when clicking a UI element.
struct HelpPopoverView: View {
    let id: HelpAnchorID
    let anchorFrame: CGRect
    let screenSize: CGSize
    
    @Environment(HelpOverlayModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(id.title)
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation {
                        model.isActive = false
                        openWindow(id: "help", value: id.topic)
                    }
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Open full help for \(id.title)")
            }
            
            Text(id.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(10)
        }
        .padding(16)
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator, lineWidth: 0.5)
        }
        .position(calculatePopoverPosition(for: anchorFrame, in: screenSize))
        .onTapGesture {
            // Absorb taps inside popover
        }
    }
    
    private func calculatePopoverPosition(for frame: CGRect, in size: CGSize) -> CGPoint {
        let spacing: CGFloat = 24
        let popoverWidth: CGFloat = 280
        let popoverHeight: CGFloat = 160
        
        var x = frame.midX
        var y = frame.maxY + spacing + (popoverHeight / 2)
        
        if y + (popoverHeight / 2) > size.height - 40 {
            y = frame.minY - spacing - (popoverHeight / 2)
        }
        
        let minX = (popoverWidth / 2) + 20
        let maxX = size.width - (popoverWidth / 2) - 20
        x = max(minX, min(x, maxX))
        
        let minY = (popoverHeight / 2) + 20
        let maxY = size.height - (popoverHeight / 2) - 20
        y = max(minY, min(y, maxY))
        
        return CGPoint(x: x, y: y)
    }
}
