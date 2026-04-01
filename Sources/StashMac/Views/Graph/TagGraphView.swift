import SwiftUI

struct TagGraphView: View {
    @Environment(StashStore.self) private var store
    @StateObject private var simulation = GraphSimulation()
    @State private var canvasOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var canvasScale: CGFloat = 1.0
    @State private var draggedNodeIndex: Int?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let transform = CGAffineTransform(translationX: totalOffset.width, y: totalOffset.height)
                    .scaledBy(x: canvasScale, y: canvasScale)

                // Draw edges
                for edge in simulation.edges {
                    guard edge.sourceIndex < simulation.nodes.count,
                          edge.targetIndex < simulation.nodes.count else { continue }
                    let from = simulation.nodes[edge.sourceIndex].position.applying(transform)
                    let to = simulation.nodes[edge.targetIndex].position.applying(transform)

                    var path = Path()
                    path.move(to: from)
                    path.addLine(to: to)

                    let lineWidth = max(1.0, min(CGFloat(edge.weight) * 0.8, 8.0)) * canvasScale
                    let opacity = min(Double(edge.weight) * 0.15, 0.6)
                    context.stroke(path, with: .color(.gray.opacity(opacity)), lineWidth: lineWidth)
                }

                // Draw nodes
                for node in simulation.nodes {
                    let pos = node.position.applying(transform)
                    let r = node.radius * canvasScale

                    let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                    let color: Color = store.filterTags.contains(node.tag.name) ? .orange : .accentColor
                    context.fill(Circle().path(in: rect), with: .color(color.opacity(0.8)))
                    context.stroke(Circle().path(in: rect), with: .color(color), lineWidth: 1.5)

                    // Label
                    let label = Text(node.tag.name)
                        .font(.system(size: max(9, 11 * canvasScale)))
                        .foregroundColor(.primary)
                    context.draw(label, at: CGPoint(x: pos.x, y: pos.y + r + 10 * canvasScale))
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .gesture(dragGesture(in: geo.size))
            .gesture(magnifyGesture)
            .onTapGesture { location in
                handleTap(at: location, in: geo.size)
            }
            .onDisappear {
                simulation.stop()
            }
            .onAppear {
                if let data = store.tagGraphData {
                    simulation.setup(data: data, canvasSize: geo.size)
                }
            }
            .onChange(of: store.tagGraphData?.nodes.count) { _, _ in
                if let data = store.tagGraphData {
                    simulation.setup(data: data, canvasSize: geo.size)
                }
            }
        }
        .navigationTitle("Tag Graph")
    }

    private var totalOffset: CGSize {
        CGSize(width: canvasOffset.width + dragOffset.width,
               height: canvasOffset.height + dragOffset.height)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = value.startLocation
                if draggedNodeIndex == nil {
                    // Hit test for node drag
                    draggedNodeIndex = hitTest(at: start, in: size)
                }
                if let idx = draggedNodeIndex {
                    // Move node
                    let delta = CGVector(
                        dx: value.translation.width / canvasScale,
                        dy: value.translation.height / canvasScale
                    )
                    simulation.nodes[idx].position = CGPoint(
                        x: simulation.nodes[idx].position.x + delta.dx - (dragOffset.width / canvasScale),
                        y: simulation.nodes[idx].position.y + delta.dy - (dragOffset.height / canvasScale)
                    )
                    simulation.nodes[idx].velocity = .zero
                    dragOffset = value.translation
                } else {
                    // Pan canvas
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                if draggedNodeIndex != nil {
                    draggedNodeIndex = nil
                    dragOffset = .zero
                } else {
                    canvasOffset.width += value.translation.width
                    canvasOffset.height += value.translation.height
                }
                dragOffset = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                canvasScale = max(0.3, min(3.0, value.magnification))
            }
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        if let idx = hitTest(at: location, in: size) {
            let tagName = simulation.nodes[idx].tag.name
            store.filterByTag(tagName, additive: NSEvent.modifierFlags.contains(.command))
        }
    }

    private func hitTest(at point: CGPoint, in size: CGSize) -> Int? {
        let transform = CGAffineTransform(translationX: totalOffset.width, y: totalOffset.height)
            .scaledBy(x: canvasScale, y: canvasScale)

        for (i, node) in simulation.nodes.enumerated() {
            let pos = node.position.applying(transform)
            let r = node.radius * canvasScale + 5 // extra tap target
            let dx = point.x - pos.x
            let dy = point.y - pos.y
            if dx * dx + dy * dy <= r * r {
                return i
            }
        }
        return nil
    }
}

// MARK: - Force Simulation

struct GraphNode {
    var tag: StashTag
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
}

struct GraphEdgeRef {
    var sourceIndex: Int
    var targetIndex: Int
    var weight: Int
}

@MainActor
class GraphSimulation: ObservableObject {
    var nodes: [GraphNode] = []
    var edges: [GraphEdgeRef] = []
    private var timer: Timer?
    private var tick = 0

    func setup(data: TagGraphData, canvasSize: CGSize) {
        timer?.invalidate()

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let maxCount = data.nodes.map { $0.count ?? 0 }.max() ?? 1
        let minR: CGFloat = 10
        let maxR: CGFloat = 35

        // Build node index
        var nameToIndex: [String: Int] = [:]
        nodes = data.nodes.enumerated().map { i, tag in
            nameToIndex[tag.name] = i
            let r = minR + (maxR - minR) * sqrt(CGFloat(tag.count ?? 0) / CGFloat(max(maxCount, 1)))
            // Arrange in a circle initially
            let angle = CGFloat(i) / CGFloat(data.nodes.count) * 2 * .pi
            let spread = min(canvasSize.width, canvasSize.height) * 0.35
            let pos = CGPoint(x: center.x + cos(angle) * spread, y: center.y + sin(angle) * spread)
            return GraphNode(tag: tag, position: pos, velocity: .zero, radius: r)
        }

        edges = data.edges.compactMap { edge in
            guard let si = nameToIndex[edge.tagA], let ti = nameToIndex[edge.tagB] else { return nil }
            return GraphEdgeRef(sourceIndex: si, targetIndex: ti, weight: edge.weight)
        }

        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.step()
            }
        }
    }

    private func step() {
        guard !nodes.isEmpty else { return }
        tick += 1

        // Cooling: reduce forces over time
        let alpha = max(0.01, 1.0 - Double(tick) / 400.0)
        if alpha <= 0.01 {
            timer?.invalidate()
            return
        }

        let repulsionK: CGFloat = 3000.0
        let dt: CGFloat = CGFloat(alpha)

        // Repulsion between all node pairs
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                var dx = nodes[i].position.x - nodes[j].position.x
                var dy = nodes[i].position.y - nodes[j].position.y
                var dist = sqrt(dx * dx + dy * dy)
                if dist < 1 { dist = 1; dx = CGFloat.random(in: -1...1); dy = CGFloat.random(in: -1...1) }

                let force = repulsionK / (dist * dist) * dt
                let fx = dx / dist * force
                let fy = dy / dist * force

                nodes[i].velocity.dx += fx
                nodes[i].velocity.dy += fy
                nodes[j].velocity.dx -= fx
                nodes[j].velocity.dy -= fy
            }
        }

        // Attraction along edges
        for edge in edges {
            let i = edge.sourceIndex
            let j = edge.targetIndex
            let dx = nodes[j].position.x - nodes[i].position.x
            let dy = nodes[j].position.y - nodes[i].position.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0 else { continue }

            let restLength: CGFloat = 100.0 / sqrt(CGFloat(max(edge.weight, 1)))
            let stiffness: CGFloat = 0.05 * dt
            let force = (dist - restLength) * stiffness
            let fx = dx / dist * force
            let fy = dy / dist * force

            nodes[i].velocity.dx += fx
            nodes[i].velocity.dy += fy
            nodes[j].velocity.dx -= fx
            nodes[j].velocity.dy -= fy
        }

        // Centering force
        let centerX = nodes.reduce(0.0) { $0 + $1.position.x } / CGFloat(nodes.count)
        let centerY = nodes.reduce(0.0) { $0 + $1.position.y } / CGFloat(nodes.count)
        for i in 0..<nodes.count {
            nodes[i].velocity.dx -= (nodes[i].position.x - centerX) * 0.005 * dt
            nodes[i].velocity.dy -= (nodes[i].position.y - centerY) * 0.005 * dt
        }

        // Update positions with velocity damping and clamping
        for i in 0..<nodes.count {
            nodes[i].velocity.dx *= 0.85
            nodes[i].velocity.dy *= 0.85

            // Clamp velocity
            let maxV: CGFloat = 15.0
            let vMag = sqrt(nodes[i].velocity.dx * nodes[i].velocity.dx + nodes[i].velocity.dy * nodes[i].velocity.dy)
            if vMag > maxV {
                nodes[i].velocity.dx = nodes[i].velocity.dx / vMag * maxV
                nodes[i].velocity.dy = nodes[i].velocity.dy / vMag * maxV
            }

            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }

        objectWillChange.send()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
