import SwiftUI
import CoreMedia

struct SpeakerMarkersOverlay: View {
    let composite: XRayTrack
    let hoverState: XRayHoverState
    let lensWidth: CGFloat
    let magnification: CGFloat
    let contentWidth: CGFloat
    let currentTimeRange: CMTimeRange?
    let speakerTimeline: [SpeakerChangeEvent]
    let speakerName: (String) -> String
    let colorForSpeakerIndex: (Int) -> Color
    let enableLens: Bool
    let onSeekPercent: (Double) -> Void
    
    private func getX(for time: Double, totalDuration: Double, W: CGFloat, xc: CGFloat, wl: CGFloat, M: CGFloat, isHovering: Bool) -> CGFloat {
        guard W > 0, wl > 0, M > 0.001, totalDuration > 0.01 else { return -1 }
        
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDuration
        guard displayDuration > 0.01 else { return -1 }
        
        let relativeTime = time - startOffset
        if relativeTime < 0 || relativeTime > displayDuration { return -1 }
        
        let tNorm = relativeTime / displayDuration
        
        if !isHovering { return CGFloat(tNorm) * W }
        
        let denominator = Double(W - wl) + (Double(wl) / Double(M))
        let k1 = 1.0 / (denominator > 0 ? denominator : 1.0)
        let xStart = Double(xc - wl/2)
        let xEnd = Double(xc + wl/2)
        
        if tNorm < xStart * k1 {
            return CGFloat(tNorm / k1)
        }
        let middleStartT = xStart * k1
        let middleDurationT = Double(wl) * (k1 / Double(M))
        if tNorm < middleStartT + middleDurationT {
            let offsetT = tNorm - middleStartT
            return CGFloat(xStart + offsetT / (k1 / Double(M)))
        }
        let endOffsetT = tNorm - (middleStartT + middleDurationT)
        return CGFloat(xEnd + endOffsetT / k1)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let currentCursorPosition = enableLens ? hoverState.cursorPosition : -1000
            let currentIsHovering = enableLens ? hoverState.isHovering : false
            let wl = lensWidth
            let M = magnification > 0.001 ? magnification : 1.0
            let totalDur = composite.duration
            
            if totalDur > 0.01 {
                ZStack(alignment: .topLeading) {
                    ForEach(speakerTimeline) { event in
                        let x = getX(
                            for: event.time,
                            totalDuration: totalDur,
                            W: contentWidth,
                            xc: currentCursorPosition,
                            wl: wl,
                            M: M,
                            isHovering: currentIsHovering
                        )
                        if x >= 0 && x <= contentWidth {
                            let speakerColor = colorForSpeakerIndex(event.speakerIndex)
                            let name = speakerName(event.speakerID)
                            let formattedT = formatTime(event.time)
                            
                            VStack(spacing: 0) {
                                Text("\(event.speakerIndex)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 12, height: 12)
                                    .background(speakerColor, in: Circle())
                                    .shadow(radius: 1)
                                    .contentShape(Circle())
                                    .onTapGesture {
                                        onSeekPercent(event.time / totalDur)
                                    }
                                    .help("\(name) at \(formattedT)")
                                
                                Rectangle()
                                    .fill(speakerColor.opacity(0.6))
                                    .frame(width: 1, height: max(0, height - 12))
                            }
                            .offset(x: x - 6) // Center the 12px circle on X
                        }
                    }
                }
            }
        }
    }
}
