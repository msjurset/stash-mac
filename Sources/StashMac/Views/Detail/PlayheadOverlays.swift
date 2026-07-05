import SwiftUI
import CoreMedia

struct PlayheadOverlays: View {
    let hoverState: XRayHoverState
    let contentWidth: CGFloat
    let tracks: [XRayTrack]
    let currentTimeRange: CMTimeRange?
    let seek: (Double) -> Void
    
    @State private var isHoveringPlayhead = false
    @State private var dragStartPlayheadTime: Double?
    
    private func calculateX(for time: Double) -> CGFloat {
        guard !tracks.isEmpty else { return -1 }
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
        
        let relativeTime = time - startOffset
        if relativeTime < -0.1 || relativeTime > displayDuration + 0.1 { return -1 }
        
        return (CGFloat(relativeTime) / CGFloat(displayDuration)) * contentWidth
    }
    
    var body: some View {
        let playheadX = calculateX(for: hoverState.playbackTime)
        
        if playheadX >= 0 && playheadX <= contentWidth {
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 2)
                .offset(x: playheadX)
                .allowsHitTesting(false)
                .zIndex(99)
            
            Image(systemName: "play.fill")
                .font(.system(size: 16))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Color.yellow)
                .offset(y: -4)
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
                .scaleEffect(isHoveringPlayhead ? 1.25 : 1.0)
                .onHover { isHoveringPlayhead = $0 }
                .resizeLeftRightCursor()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartPlayheadTime == nil {
                                dragStartPlayheadTime = hoverState.playbackTime
                            }
                            guard let startTime = dragStartPlayheadTime else { return }
                            let totalDur = tracks.map(\.duration).max() ?? 1.0
                            let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
                            let deltaT = (Double(value.translation.width) / Double(contentWidth)) * displayDuration
                            let targetTime = max(0, min(startTime + deltaT, totalDur))
                            seek(targetTime)
                        }
                        .onEnded { _ in
                            dragStartPlayheadTime = nil
                        }
                )
                .offset(x: playheadX - 22)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .zIndex(100)
        }
    }
}

