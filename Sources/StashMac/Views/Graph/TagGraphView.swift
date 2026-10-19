import SwiftUI
import AppKit

struct TagGraphView: View {
    @Environment(StashStore.self) private var store
    @StateObject private var simulation = GraphSimulation()

    var body: some View {
        GeometryReader { geo in
            TagGraphCanvasRepresentable(
                simulation: simulation,
                filterTags: store.filterTags,
                onSelectTag: { tagName, isAdditive in
                    store.filterByTag(tagName, additive: isAdditive)
                }
            )
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
        .toolbar {
            ToolbarItem {
                ContextualHelpButton(topic: .organizing, isToolbarItem: true)
            }
        }
    }
}

// MARK: - AppKit Canvas View

struct TagGraphCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var simulation: GraphSimulation
    var filterTags: Set<String>
    var onSelectTag: (String, Bool) -> Void

    func makeNSView(context: Context) -> TagGraphCanvasNSView {
        let view = TagGraphCanvasNSView()
        view.simulation = simulation
        view.filterTags = filterTags
        view.onSelectTag = onSelectTag
        return view
    }

    func updateNSView(_ nsView: TagGraphCanvasNSView, context: Context) {
        nsView.simulation = simulation
        nsView.filterTags = filterTags
        nsView.onSelectTag = onSelectTag
        nsView.needsDisplay = true
    }
}

final class TagGraphCanvasNSView: NSView {
    var simulation: GraphSimulation?
    var filterTags: Set<String> = []
    var onSelectTag: ((String, Bool) -> Void)?

    private var canvasOffset: CGPoint = .zero
    private var canvasScale: CGFloat = 1.0

    private var draggedNodeIndex: Int?
    private var lastMouseLocation: CGPoint = .zero
    private var mouseDownLocation: CGPoint = .zero
    private var isDraggingOrPanning = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastMouseLocation = location
        mouseDownLocation = location
        isDraggingOrPanning = false

        if let idx = hitTestNode(at: location) {
            draggedNodeIndex = idx
            simulation?.wake()
        } else {
            draggedNodeIndex = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let dx = location.x - lastMouseLocation.x
        let dy = location.y - lastMouseLocation.y
        lastMouseLocation = location

        if abs(location.x - mouseDownLocation.x) > 3 || abs(location.y - mouseDownLocation.y) > 3 {
            isDraggingOrPanning = true
        }

        if let idx = draggedNodeIndex, let sim = simulation, idx < sim.nodes.count {
            sim.nodes[idx].position.x += dx / canvasScale
            sim.nodes[idx].position.y += dy / canvasScale
            sim.nodes[idx].velocity = .zero
        } else {
            canvasOffset.x += dx
            canvasOffset.y += dy
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !isDraggingOrPanning, let idx = hitTestNode(at: location), let sim = simulation, idx < sim.nodes.count {
            let tag = sim.nodes[idx].tag.name
            let isCmd = event.modifierFlags.contains(.command)
            onSelectTag?(tag, isCmd)
        }
        draggedNodeIndex = nil
        isDraggingOrPanning = false
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let zoomFactor = 1.0 + (event.scrollingDeltaY * 0.005)
            let location = convert(event.locationInWindow, from: nil)
            applyZoom(by: zoomFactor, anchor: location)
        } else {
            canvasOffset.x += event.scrollingDeltaX
            canvasOffset.y += event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        let zoomFactor = 1.0 + event.magnification
        let location = convert(event.locationInWindow, from: nil)
        applyZoom(by: zoomFactor, anchor: location)
    }

    private func applyZoom(by delta: CGFloat, anchor: CGPoint) {
        let oldScale = canvasScale
        let newScale = max(0.3, min(3.0, oldScale * delta))
        guard newScale != oldScale else { return }
        let k = newScale / oldScale
        canvasOffset.x = anchor.x - (anchor.x - canvasOffset.x) * k
        canvasOffset.y = anchor.y - (anchor.y - canvasOffset.y) * k
        canvasScale = newScale
        needsDisplay = true
    }

    private func hitTestNode(at screenPoint: CGPoint) -> Int? {
        guard let sim = simulation else { return nil }
        let worldPoint = CGPoint(
            x: (screenPoint.x - canvasOffset.x) / canvasScale,
            y: (screenPoint.y - canvasOffset.y) / canvasScale
        )
        for (i, node) in sim.nodes.enumerated() {
            let dx = worldPoint.x - node.position.x
            let dy = worldPoint.y - node.position.y
            let r = node.radius + 5 / canvasScale
            if dx * dx + dy * dy <= r * r {
                return i
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let sim = simulation else { return }

        // Background
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        context.saveGState()
        context.translateBy(x: canvasOffset.x, y: canvasOffset.y)
        context.scaleBy(x: canvasScale, y: canvasScale)

        // Draw edges
        for edge in sim.edges {
            guard edge.sourceIndex < sim.nodes.count, edge.targetIndex < sim.nodes.count else { continue }
            let from = sim.nodes[edge.sourceIndex].position
            let to = sim.nodes[edge.targetIndex].position

            let lineWidth = max(1.0, min(CGFloat(edge.weight) * 0.8, 8.0))
            let opacity = min(Double(edge.weight) * 0.15, 0.6)

            context.setStrokeColor(NSColor.gray.withAlphaComponent(opacity).cgColor)
            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }

        // Draw nodes
        let textFont = NSFont.systemFont(ofSize: 11)
        let textColor = NSColor.labelColor

        for node in sim.nodes {
            let pos = node.position
            let r = node.radius
            let isFiltered = filterTags.contains(node.tag.name)

            let fillColor = isFiltered ? NSColor.systemOrange.withAlphaComponent(0.8) : NSColor.controlAccentColor.withAlphaComponent(0.8)
            let strokeColor = isFiltered ? NSColor.systemOrange : NSColor.controlAccentColor

            let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)

            context.setFillColor(fillColor.cgColor)
            context.fillEllipse(in: rect)

            context.setStrokeColor(strokeColor.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: rect)

            // Draw label
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: textColor
            ]
            let str = NSString(string: node.tag.name)
            let strSize = str.size(withAttributes: attrs)
            let textPoint = CGPoint(x: pos.x - strSize.width / 2.0, y: pos.y + r + 4 / canvasScale)

            str.draw(at: textPoint, withAttributes: attrs)
        }

        context.restoreGState()
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
    private var totalTicks = 300

    func setup(data: TagGraphData, canvasSize: CGSize) {
        timer?.invalidate()
        timer = nil

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
            let angle = CGFloat(i) / CGFloat(max(data.nodes.count, 1)) * 2 * .pi
            let spread = min(canvasSize.width, canvasSize.height) * 0.35
            let pos = CGPoint(x: center.x + cos(angle) * spread, y: center.y + sin(angle) * spread)
            return GraphNode(tag: tag, position: pos, velocity: .zero, radius: r)
        }

        edges = data.edges.compactMap { edge in
            guard let si = nameToIndex[edge.tagA], let ti = nameToIndex[edge.tagB] else { return nil }
            return GraphEdgeRef(sourceIndex: si, targetIndex: ti, weight: edge.weight)
        }

        // Fast synchronous pre-pass (80 ticks) so layout is already semi-stable when rendered
        for _ in 0..<80 {
            performStep(dtScale: 1.0)
        }

        tick = 80
        startTimer()
    }

    func wake() {
        if timer == nil && !nodes.isEmpty {
            tick = max(0, totalTicks - 100) // gentle wake for 100 ticks
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                self.step()
            }
        }
    }

    private func step() {
        guard !nodes.isEmpty else { return }
        tick += 1

        if tick >= totalTicks {
            stop()
            return
        }

        let alpha = max(0.01, 1.0 - Double(tick) / Double(totalTicks))
        performStep(dtScale: alpha)
        objectWillChange.send()
    }

    private func performStep(dtScale: Double) {
        let repulsionK: CGFloat = 3000.0
        let dt: CGFloat = CGFloat(dtScale)
        let count = nodes.count

        // Repulsion between all node pairs
        for i in 0..<count {
            let posI = nodes[i].position
            for j in (i + 1)..<count {
                let posJ = nodes[j].position
                var dx = posI.x - posJ.x
                var dy = posI.y - posJ.y
                var dist = sqrt(dx * dx + dy * dy)
                if dist < 1 { dist = 1; dx = CGFloat.random(in: -1...1); dy = CGFloat.random(in: -1...1) }
                if dist > 600 { continue } // distant nodes have negligible repulsion force

                let force = (repulsionK / (dist * dist)) * dt
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force

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
            guard i < count && j < count else { continue }
            let dx = nodes[j].position.x - nodes[i].position.x
            let dy = nodes[j].position.y - nodes[i].position.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0 else { continue }

            let restLength: CGFloat = 100.0 / sqrt(CGFloat(max(edge.weight, 1)))
            let stiffness: CGFloat = 0.05 * dt
            let force = (dist - restLength) * stiffness
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force

            nodes[i].velocity.dx += fx
            nodes[i].velocity.dy += fy
            nodes[j].velocity.dx -= fx
            nodes[j].velocity.dy -= fy
        }

        // Centering force
        let centerX = nodes.reduce(0.0) { $0 + $1.position.x } / CGFloat(max(count, 1))
        let centerY = nodes.reduce(0.0) { $0 + $1.position.y } / CGFloat(max(count, 1))
        for i in 0..<count {
            nodes[i].velocity.dx -= (nodes[i].position.x - centerX) * 0.005 * dt
            nodes[i].velocity.dy -= (nodes[i].position.y - centerY) * 0.005 * dt
        }

        // Update positions with velocity damping and clamping
        let maxV: CGFloat = 15.0
        for i in 0..<count {
            nodes[i].velocity.dx *= 0.85
            nodes[i].velocity.dy *= 0.85

            let vMag = sqrt(nodes[i].velocity.dx * nodes[i].velocity.dx + nodes[i].velocity.dy * nodes[i].velocity.dy)
            if vMag > maxV {
                nodes[i].velocity.dx = (nodes[i].velocity.dx / vMag) * maxV
                nodes[i].velocity.dy = (nodes[i].velocity.dy / vMag) * maxV
            }

            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
