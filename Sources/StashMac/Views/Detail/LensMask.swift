import SwiftUI

struct LensMask: View {
    let hoverState: XRayHoverState
    let lensWidth: CGFloat
    let enableLens: Bool
    
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            if enableLens && hoverState.isHovering {
                let xc = hoverState.cursorPosition
                let rect = CGRect(x: xc - lensWidth/2, y: 0, width: lensWidth, height: size.height)
                context.blendMode = .clear
                context.fill(Path(rect), with: .color(.black))
            }
        }
    }
}
