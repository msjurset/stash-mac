import SwiftUI
import AppKit
import QuartzCore
import simd

struct TagGraphView: View {
    @Environment(StashStore.self) private var store
    @StateObject private var simulation = GraphSimulation()
    @State private var renamingTag: StashTag?
    @State private var newTagName = ""
    @State private var focusedTagName: String?
    @State private var currentCanvasSize: CGSize = CGSize(width: 800, height: 600)

    // Persisted watermark display toggles (remembers last state across navigations & launches;
    // Aa, 2+, and Connected/No-Orphans default to ON on first load)
    @AppStorage("tagGraph.v2.showNodeCounts") private var showNodeCounts = false
    @AppStorage("tagGraph.v2.showNodeLabels") private var showNodeLabels = true
    @AppStorage("tagGraph.v2.minCountTwo") private var minCountTwo = true
    @AppStorage("tagGraph.v2.hideOrphans") private var hideOrphans = true
    @AppStorage("tagGraph.v2.showEdgeWeights") private var showEdgeWeights = false

    private func computeFilteredData(
        raw: TagGraphData?,
        minTwo: Bool,
        noOrphans: Bool
    ) -> TagGraphData? {
        guard let raw else { return nil }
        return Self.filterGraphData(
            raw,
            minCountTwo: minTwo,
            hideOrphans: noOrphans
        )
    }

    static func filterGraphData(
        _ data: TagGraphData,
        minCountTwo: Bool,
        hideOrphans: Bool
    ) -> TagGraphData {
        var nodes = data.nodes
        if minCountTwo {
            nodes = nodes.filter { ($0.count ?? 0) >= 2 }
        }
        let survivingNames = Set(nodes.map(\.name))
        let edges = data.edges.filter {
            survivingNames.contains($0.tagA) && survivingNames.contains($0.tagB)
        }
        if hideOrphans {
            var connected = Set<String>()
            for edge in edges {
                connected.insert(edge.tagA)
                connected.insert(edge.tagB)
            }
            nodes = nodes.filter { connected.contains($0.name) }
        }
        return TagGraphData(nodes: nodes, edges: edges)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TagGraphCanvasRepresentable(
                    simulation: simulation,
                    filterTags: store.filterTags,
                    showNodeCounts: showNodeCounts,
                    showEdgeWeights: showEdgeWeights,
                    showNodeLabels: showNodeLabels,
                    onSelectTag: { tagName, isAdditive in
                        store.selectedItemID = nil
                        store.filterByTag(tagName, additive: isAdditive)
                    },
                    onEnsureSelectedTag: { tagName in
                        store.selectedItemID = nil
                        if store.filterTags != [tagName] {
                            store.filterByTag(tagName, additive: false)
                        }
                    },
                    onSelectTagAndNeighbors: { tagNames in
                        store.selectedItemID = nil
                        store.filterType = nil
                        store.filterCollection = nil
                        store.searchQuery = ""
                        store.filterTags = Set(tagNames)
                        store.refresh()
                    },
                    onOpenTagInList: { tag in
                        store.recordNavigationHistory()
                        store.applyNavigation(.tag(tag))
                    },
                    onRenameTag: { tag in
                        renamingTag = tag
                        newTagName = tag.name
                    },
                    onExportTag: { tagName in
                        let suggested = ExportPanels.suggestedFilename(forScopeLabel: "tag-\(tagName)")
                        guard let outPath = ExportPanels.chooseExportDestination(suggestedName: suggested) else { return }
                        store.exportItems(scope: .tag(tagName), to: outPath)
                    },
                    onClearSelection: {
                        store.selectedItemID = nil
                        if !store.filterTags.isEmpty {
                            store.filterTags = []
                            store.refresh()
                        }
                    },
                    onFocusChanged: { focusedName in
                        focusedTagName = focusedName
                    }
                )
                .onDisappear {
                    simulation.stop()
                }
                .onAppear {
                    currentCanvasSize = geo.size
                    reloadGraphSimulation(
                        raw: store.tagGraphData,
                        minTwo: minCountTwo,
                        noOrphans: hideOrphans,
                        size: geo.size
                    )
                }
                .onChange(of: geo.size) { _, newSize in
                    if newSize.width > 10 && newSize.height > 10 {
                        currentCanvasSize = newSize
                    }
                }
                .onChange(of: store.tagGraphData?.nodes.map(\.name)) { _, _ in
                    reloadGraphSimulation(
                        raw: store.tagGraphData,
                        minTwo: minCountTwo,
                        noOrphans: hideOrphans,
                        size: currentCanvasSize
                    )
                }
                .onChange(of: hideOrphans) { _, newHideOrphans in
                    reloadGraphSimulation(
                        raw: store.tagGraphData,
                        minTwo: minCountTwo,
                        noOrphans: newHideOrphans,
                        size: currentCanvasSize
                    )
                }
                .onChange(of: minCountTwo) { _, newMinCountTwo in
                    reloadGraphSimulation(
                        raw: store.tagGraphData,
                        minTwo: newMinCountTwo,
                        noOrphans: hideOrphans,
                        size: currentCanvasSize
                    )
                }

                // Top-Right Floating Focus Pill (when a node is double-clicked)
                VStack {
                    HStack {
                        Spacer()
                        if let focusedTagName {
                            HStack(spacing: 6) {
                                Image(systemName: "scope")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text("Focused: #\(focusedTagName)")
                                    .font(.caption.bold())
                                Button {
                                    simulation.clearFocus()
                                    self.focusedTagName = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .help("Release focus ring (or click empty space)")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .padding(12)
                    Spacer()
                }

                // Bottom-Right Corner Watermark Toggles
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Spacer()
                        if let total = store.tagGraphData?.nodes.count,
                           let shown = computeFilteredData(
                               raw: store.tagGraphData,
                               minTwo: minCountTwo,
                               noOrphans: hideOrphans
                           )?.nodes.count,
                           shown < total {
                            Text("\(shown)/\(total) tags")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.75))
                                .padding(.trailing, 2)
                        }

                        watermarkToggle(
                            label: "#",
                            systemImage: nil,
                            active: showNodeCounts,
                            help: showNodeCounts
                                ? "Hide item counts inside nodes"
                                : "Show item counts inside nodes"
                        ) {
                            showNodeCounts.toggle()
                        }

                        watermarkToggle(
                            label: "Aa",
                            systemImage: nil,
                            active: showNodeLabels,
                            help: showNodeLabels
                                ? "Hide tag labels on unselected nodes"
                                : "Show tag labels on all nodes"
                        ) {
                            showNodeLabels.toggle()
                        }

                        watermarkToggle(
                            label: "2+",
                            systemImage: nil,
                            active: minCountTwo,
                            help: minCountTwo
                                ? "Show single-item tags (currently filtering to 2+ items)"
                                : "Hide single-item tags (show only tags with 2+ items)"
                        ) {
                            minCountTwo.toggle()
                        }

                        watermarkToggle(
                            label: nil,
                            systemImage: "point.3.connected.trianglepath.dotted",
                            active: hideOrphans,
                            help: hideOrphans
                                ? "Show orphan tags (currently hiding unconnected nodes)"
                                : "Hide orphan tags (unconnected nodes with 0 edges)"
                        ) {
                            hideOrphans.toggle()
                        }

                        watermarkToggle(
                            label: nil,
                            systemImage: "link.badge.plus",
                            active: showEdgeWeights,
                            help: showEdgeWeights
                                ? "Hide co-occurrence counts on connected edges"
                                : "Show co-occurrence counts on connected edges"
                        ) {
                            showEdgeWeights.toggle()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .navigationTitle("Tag Graph")
        .toolbar {
            ToolbarItem {
                ContextualHelpButton(topic: .organizing, isToolbarItem: true)
            }
        }
        .sheet(isPresented: Binding(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )) {
            RenameTagSheet(
                originalName: renamingTag?.name ?? "",
                newName: $newTagName,
                onCommit: {
                    if let tag = renamingTag, !newTagName.trimmingCharacters(in: .whitespaces).isEmpty {
                        store.renameTag(old: tag.name, new: newTagName.trimmingCharacters(in: .whitespaces))
                    }
                    renamingTag = nil
                },
                onCancel: { renamingTag = nil }
            )
        }
    }

    private func reloadGraphSimulation(
        raw: TagGraphData?,
        minTwo: Bool,
        noOrphans: Bool,
        size: CGSize
    ) {
        if let data = computeFilteredData(raw: raw, minTwo: minTwo, noOrphans: noOrphans) {
            simulation.setup(data: data, canvasSize: size)
            focusedTagName = simulation.focusedTagName
        }
    }

    @ViewBuilder
    private func watermarkToggle(
        label: String?,
        systemImage: String?,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: active ? .bold : .medium, design: .monospaced))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                }
            }
            .foregroundStyle(active ? Color.orange : Color.secondary.opacity(0.65))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.orange.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(active ? Color.orange.opacity(0.45) : Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .id("\(label ?? systemImage ?? "toggle")-\(active)")
    }
}

// MARK: - GPU-Backed AppKit Canvas View (CoreAnimation / Metal Composited)

struct TagGraphCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var simulation: GraphSimulation
    var filterTags: Set<String>
    var showNodeCounts: Bool
    var showEdgeWeights: Bool
    var showNodeLabels: Bool
    var onSelectTag: (String, Bool) -> Void
    var onEnsureSelectedTag: (String) -> Void
    var onSelectTagAndNeighbors: ([String]) -> Void
    var onOpenTagInList: (StashTag) -> Void
    var onRenameTag: (StashTag) -> Void
    var onExportTag: (String) -> Void
    var onClearSelection: () -> Void
    var onFocusChanged: (String?) -> Void

    func makeNSView(context: Context) -> TagGraphCanvasNSView {
        let view = TagGraphCanvasNSView()
        bind(view)
        return view
    }

    func updateNSView(_ nsView: TagGraphCanvasNSView, context: Context) {
        bind(nsView)
        nsView.syncSelectionAppearance()
    }

    private func bind(_ view: TagGraphCanvasNSView) {
        view.simulation = simulation
        view.filterTags = filterTags
        view.showNodeCounts = showNodeCounts
        view.showEdgeWeights = showEdgeWeights
        view.showNodeLabels = showNodeLabels
        view.onSelectTag = onSelectTag
        view.onEnsureSelectedTag = onEnsureSelectedTag
        view.onSelectTagAndNeighbors = onSelectTagAndNeighbors
        view.onOpenTagInList = onOpenTagInList
        view.onRenameTag = onRenameTag
        view.onExportTag = onExportTag
        view.onClearSelection = onClearSelection
        view.onFocusChanged = onFocusChanged
    }
}

@MainActor
final class TagGraphCanvasNSView: NSView {
    var simulation: GraphSimulation? {
        didSet {
            guard simulation !== oldValue else { return }
            wireSimulationCallbacks()
            rebuildSceneLayers()
        }
    }
    var filterTags: Set<String> = [] {
        didSet { if filterTags != oldValue { syncSelectionAppearance() } }
    }
    var showNodeCounts: Bool = false {
        didSet { if showNodeCounts != oldValue { syncSelectionAppearance() } }
    }
    var showEdgeWeights: Bool = false {
        didSet { if showEdgeWeights != oldValue { syncSelectionAppearance() } }
    }
    var showNodeLabels: Bool = true {
        didSet { if showNodeLabels != oldValue { syncSelectionAppearance() } }
    }

    var onSelectTag: ((String, Bool) -> Void)?
    var onEnsureSelectedTag: ((String) -> Void)?
    var onSelectTagAndNeighbors: (([String]) -> Void)?
    var onOpenTagInList: ((StashTag) -> Void)?
    var onRenameTag: ((StashTag) -> Void)?
    var onExportTag: ((String) -> Void)?
    var onClearSelection: (() -> Void)?
    var onFocusChanged: ((String?) -> Void)?

    private var canvasOffset: CGPoint = .zero
    private var canvasScale: CGFloat = 1.0

    private var draggedNodeIndex: Int?
    private var contextMenuNodeIndex: Int?
    private var lastMouseLocation: CGPoint = .zero
    private var mouseDownLocation: CGPoint = .zero
    private var isDraggingOrPanning = false

    // GPU-composited CoreAnimation layer hierarchy
    private let worldLayer = CALayer()
    private let focusRingLayer = CAShapeLayer()
    private let backgroundEdgesLayer = CAShapeLayer()
    private let highlightedEdgesLayer = CAShapeLayer()
    private var edgeWeightLayers: [CATextLayer] = []
    private var nodeCircleLayers: [CALayer] = []
    private var nodeCountLayers: [CATextLayer] = []
    private var nodeLabelLayers: [CATextLayer] = []

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.controlBackgroundColor.cgColor
        root.masksToBounds = true

        worldLayer.anchorPoint = .zero
        worldLayer.position = .zero
        root.addSublayer(worldLayer)

        focusRingLayer.fillColor = nil
        focusRingLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.28).cgColor
        focusRingLayer.lineWidth = 1.5
        focusRingLayer.lineDashPattern = [6, 5]
        focusRingLayer.isHidden = true
        worldLayer.addSublayer(focusRingLayer)

        backgroundEdgesLayer.fillColor = nil
        backgroundEdgesLayer.strokeColor = NSColor.gray.withAlphaComponent(0.28).cgColor
        backgroundEdgesLayer.lineWidth = 1.4
        backgroundEdgesLayer.lineCap = .round
        worldLayer.addSublayer(backgroundEdgesLayer)

        highlightedEdgesLayer.fillColor = nil
        highlightedEdgesLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.75).cgColor
        highlightedEdgesLayer.lineWidth = 2.4
        highlightedEdgesLayer.lineCap = .round
        worldLayer.addSublayer(highlightedEdgesLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            syncSelectionAppearance()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        for label in nodeLabelLayers { label.contentsScale = scale }
        for countLayer in nodeCountLayers { countLayer.contentsScale = scale }
        for edgeLayer in edgeWeightLayers { edgeLayer.contentsScale = scale }
    }

    private func wireSimulationCallbacks() {
        simulation?.onStructureRebuilt = { [weak self] in
            self?.rebuildSceneLayers()
        }
        simulation?.onTick = { [weak self] in
            self?.syncPositionsFromSimulation()
        }
        simulation?.onCameraCenterRequest = { [weak self] worldPoint in
            self?.centerCamera(on: worldPoint, animated: true)
        }
    }

    // MARK: - Layer Construction & GPU Sync

    func rebuildSceneLayers() {
        guard let sim = simulation else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        edgeWeightLayers.forEach { $0.removeFromSuperlayer() }
        nodeCircleLayers.forEach { $0.removeFromSuperlayer() }
        nodeCountLayers.forEach { $0.removeFromSuperlayer() }
        nodeLabelLayers.forEach { $0.removeFromSuperlayer() }
        edgeWeightLayers.removeAll(keepingCapacity: true)
        nodeCircleLayers.removeAll(keepingCapacity: true)
        nodeCountLayers.removeAll(keepingCapacity: true)
        nodeLabelLayers.removeAll(keepingCapacity: true)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let edgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)

        for edge in sim.edges {
            let wLabel = CATextLayer()
            wLabel.string = "\(edge.weight)"
            wLabel.font = edgeFont
            wLabel.fontSize = 9
            wLabel.alignmentMode = .center
            wLabel.contentsScale = scale
            wLabel.bounds = CGRect(x: 0, y: 0, width: 20, height: 13)
            wLabel.cornerRadius = 6.5
            wLabel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
            wLabel.foregroundColor = NSColor.systemOrange.cgColor
            wLabel.borderColor = NSColor.systemOrange.withAlphaComponent(0.45).cgColor
            wLabel.borderWidth = 0.8
            wLabel.isHidden = true
            worldLayer.addSublayer(wLabel)
            edgeWeightLayers.append(wLabel)
        }

        for node in sim.nodes {
            let r = node.radius
            let circle = CALayer()
            circle.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            circle.cornerRadius = r
            circle.borderWidth = 1.5
            circle.contentsScale = scale
            worldLayer.addSublayer(circle)
            nodeCircleLayers.append(circle)

            // Interior count badge layer (centered inside the node circle)
            let countFontSize = max(8.5, min(13.0, r * 0.62))
            let countFont = NSFont.monospacedDigitSystemFont(ofSize: countFontSize, weight: .bold)
            let countLayer = CATextLayer()
            countLayer.string = "\(node.tag.count ?? 0)"
            countLayer.font = countFont
            countLayer.fontSize = countFontSize
            countLayer.alignmentMode = .center
            countLayer.contentsScale = scale
            countLayer.bounds = CGRect(x: 0, y: 0, width: r * 2, height: countFontSize + 3)
            countLayer.foregroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
            countLayer.isHidden = !showNodeCounts
            worldLayer.addSublayer(countLayer)
            nodeCountLayers.append(countLayer)

            // Tag name label layer beneath node circle
            let str = node.tag.name as NSString
            let textSize = str.size(withAttributes: labelAttrs)
            let label = CATextLayer()
            label.string = node.tag.name
            label.font = labelFont
            label.fontSize = 11
            label.alignmentMode = .center
            label.contentsScale = scale
            label.bounds = CGRect(x: 0, y: 0, width: ceil(textSize.width) + 6, height: ceil(textSize.height) + 2)
            worldLayer.addSublayer(label)
            nodeLabelLayers.append(label)
        }

        CATransaction.commit()
        syncPositionsFromSimulation()
        syncSelectionAppearance()
    }

    func syncPositionsFromSimulation() {
        guard let sim = simulation, nodeCircleLayers.count == sim.nodes.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (i, node) in sim.nodes.enumerated() {
            let pos = node.cgPosition
            nodeCircleLayers[i].position = pos
            nodeCountLayers[i].position = pos
            nodeLabelLayers[i].position = CGPoint(
                x: pos.x,
                y: pos.y + node.radius + 9
            )
        }

        if let fIdx = sim.focusedNodeIndex, fIdx < sim.nodes.count {
            let center = sim.nodes[fIdx].cgPosition
            let rr = sim.focusRingRadius
            let rect = CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)
            focusRingLayer.path = CGPath(ellipseIn: rect, transform: nil)
            focusRingLayer.isHidden = false
        } else {
            focusRingLayer.isHidden = true
        }

        let bgPath = CGMutablePath()
        let hiPath = CGMutablePath()
        let activeIndices = highlightedNodeIndices(in: sim)
        let hasActiveOrFocus = (sim.focusedNodeIndex != nil || !activeIndices.isEmpty)

        for (eIdx, edge) in sim.edges.enumerated() {
            guard edge.sourceIndex < sim.nodes.count, edge.targetIndex < sim.nodes.count else { continue }
            let from = sim.nodes[edge.sourceIndex].cgPosition
            let to = sim.nodes[edge.targetIndex].cgPosition
            let isHighlighted: Bool
            if let fIdx = sim.focusedNodeIndex {
                isHighlighted = (edge.sourceIndex == fIdx || edge.targetIndex == fIdx)
            } else if !activeIndices.isEmpty {
                isHighlighted = activeIndices.contains(edge.sourceIndex) || activeIndices.contains(edge.targetIndex)
            } else {
                isHighlighted = false
            }

            if isHighlighted {
                hiPath.move(to: from)
                hiPath.addLine(to: to)
            } else {
                bgPath.move(to: from)
                bgPath.addLine(to: to)
            }

            if eIdx < edgeWeightLayers.count {
                let showBadge = showEdgeWeights && (isHighlighted || (!hasActiveOrFocus && edge.weight >= 2))
                edgeWeightLayers[eIdx].isHidden = !showBadge
                if showBadge {
                    edgeWeightLayers[eIdx].position = CGPoint(
                        x: (from.x + to.x) * 0.5,
                        y: (from.y + to.y) * 0.5
                    )
                }
            }
        }
        backgroundEdgesLayer.path = bgPath
        highlightedEdgesLayer.path = hiPath

        CATransaction.commit()
    }

    func syncSelectionAppearance() {
        guard let sim = simulation, nodeCircleLayers.count == sim.nodes.count else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let activeIndices = highlightedNodeIndices(in: sim)
            let neighborSet = sim.focusedNeighborIndices
            let hasFocus = sim.focusedNodeIndex != nil
            let hasSelection = !activeIndices.isEmpty

            let selectedFill = NSColor.systemOrange.withAlphaComponent(0.88).cgColor
            let selectedStroke = NSColor.systemOrange.cgColor
            let neighborFill = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
            let neighborStroke = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
            let normalFill = NSColor.controlAccentColor.withAlphaComponent(0.80).cgColor
            let normalStroke = NSColor.controlAccentColor.cgColor
            let dimmedFill = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
            let dimmedStroke = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor

            let primaryText = NSColor.labelColor.cgColor
            let dimmedText = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
            let brightCountText = NSColor.white.withAlphaComponent(0.95).cgColor
            let dimmedCountText = NSColor.white.withAlphaComponent(0.38).cgColor

            var selectionNeighbors = Set<Int>()
            if !activeIndices.isEmpty {
                for edge in sim.edges {
                    if activeIndices.contains(edge.sourceIndex) {
                        selectionNeighbors.insert(edge.targetIndex)
                    }
                    if activeIndices.contains(edge.targetIndex) {
                        selectionNeighbors.insert(edge.sourceIndex)
                    }
                }
            }

            for (i, node) in sim.nodes.enumerated() {
                let isSelected = filterTags.contains(node.tag.name) || sim.focusedNodeIndex == i
                let isNeighbor = neighborSet.contains(i) || selectionNeighbors.contains(i)

                nodeCountLayers[i].isHidden = !showNodeCounts
                // When showNodeLabels is off, still show labels on selected/focused node and its 1st-degree neighbors
                nodeLabelLayers[i].isHidden = !(showNodeLabels || isSelected || isNeighbor)

                if isSelected {
                    nodeCircleLayers[i].backgroundColor = selectedFill
                    nodeCircleLayers[i].borderColor = selectedStroke
                    nodeCircleLayers[i].borderWidth = 2.5
                    nodeLabelLayers[i].foregroundColor = primaryText
                    nodeCountLayers[i].foregroundColor = brightCountText
                } else if isNeighbor {
                    nodeCircleLayers[i].backgroundColor = neighborFill
                    nodeCircleLayers[i].borderColor = neighborStroke
                    nodeCircleLayers[i].borderWidth = 2.0
                    nodeLabelLayers[i].foregroundColor = primaryText
                    nodeCountLayers[i].foregroundColor = brightCountText
                } else if hasFocus || hasSelection {
                    nodeCircleLayers[i].backgroundColor = dimmedFill
                    nodeCircleLayers[i].borderColor = dimmedStroke
                    nodeCircleLayers[i].borderWidth = 1.2
                    nodeLabelLayers[i].foregroundColor = dimmedText
                    nodeCountLayers[i].foregroundColor = dimmedCountText
                } else {
                    nodeCircleLayers[i].backgroundColor = normalFill
                    nodeCircleLayers[i].borderColor = normalStroke
                    nodeCircleLayers[i].borderWidth = 1.5
                    nodeLabelLayers[i].foregroundColor = primaryText
                    nodeCountLayers[i].foregroundColor = brightCountText
                }
            }

            backgroundEdgesLayer.strokeColor = (hasFocus || hasSelection)
                ? NSColor.gray.withAlphaComponent(0.14).cgColor
                : NSColor.gray.withAlphaComponent(0.30).cgColor

            CATransaction.commit()
        }
        syncPositionsFromSimulation()
    }

    private func highlightedNodeIndices(in sim: GraphSimulation) -> Set<Int> {
        var set = Set<Int>()
        for (i, node) in sim.nodes.enumerated() where filterTags.contains(node.tag.name) {
            set.insert(i)
        }
        return set
    }

    private func updateWorldTransform(animated: Bool = false) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, canvasOffset.x, canvasOffset.y, 0)
        transform = CATransform3DScale(transform, canvasScale, canvasScale, 1)
        worldLayer.sublayerTransform = transform
        CATransaction.commit()
    }

    private func centerCamera(on worldPoint: CGPoint, animated: Bool) {
        let viewCenter = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        canvasOffset = CGPoint(
            x: viewCenter.x - worldPoint.x * canvasScale,
            y: viewCenter.y - worldPoint.y * canvasScale
        )
        updateWorldTransform(animated: animated)
    }

    // MARK: - Mouse & Gesture Events

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastMouseLocation = location
        mouseDownLocation = location
        isDraggingOrPanning = false

        if let idx = hitTestNode(at: location) {
            draggedNodeIndex = idx
            if event.clickCount == 1 {
                simulation?.wake(ticks: 60)
            }
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
            sim.nodes[idx].position.x += Float(dx / canvasScale)
            sim.nodes[idx].position.y += Float(dy / canvasScale)
            sim.nodes[idx].velocity = .zero
            sim.wake(ticks: 80)
            syncPositionsFromSimulation()
        } else {
            canvasOffset.x += dx
            canvasOffset.y += dy
            updateWorldTransform(animated: false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        defer {
            draggedNodeIndex = nil
            isDraggingOrPanning = false
        }

        guard !isDraggingOrPanning, let sim = simulation else { return }

        if let idx = hitTestNode(at: location), idx < sim.nodes.count {
            let tag = sim.nodes[idx].tag.name
            if event.clickCount >= 2 {
                // Double-click node: focus node at center with 1st-degree ring
                // and push non-neighbor nodes out of the way.
                onEnsureSelectedTag?(tag)
                if sim.focusedNodeIndex == idx {
                    sim.clearFocus()
                    onFocusChanged?(nil)
                } else {
                    sim.focusNode(at: idx, canvasSize: bounds.size)
                    onFocusChanged?(tag)
                }
                syncSelectionAppearance()
            } else {
                let isCmd = event.modifierFlags.contains(.command)
                onSelectTag?(tag, isCmd)
            }
        } else {
            // Clicked empty canvas space: unselect tags, release focus ring, and reset graph view
            let hadFocus = (sim.focusedNodeIndex != nil)
            let hadSelection = !filterTags.isEmpty
            let hadCameraTransform = (canvasScale != 1.0 || canvasOffset != .zero)

            if hadFocus {
                sim.clearFocus()
                onFocusChanged?(nil)
            }
            if hadSelection {
                onClearSelection?()
            }
            if hadFocus || hadCameraTransform {
                canvasScale = 1.0
                canvasOffset = .zero
                updateWorldTransform(animated: true)
            }
            syncSelectionAppearance()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let zoomFactor = 1.0 + (event.scrollingDeltaY * 0.005)
            let location = convert(event.locationInWindow, from: nil)
            applyZoom(by: zoomFactor, anchor: location)
        } else {
            canvasOffset.x += event.scrollingDeltaX
            canvasOffset.y += event.scrollingDeltaY
            updateWorldTransform(animated: false)
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
        updateWorldTransform(animated: false)
    }

    private func hitTestNode(at screenPoint: CGPoint) -> Int? {
        guard let sim = simulation else { return nil }
        let worldX = Float((screenPoint.x - canvasOffset.x) / canvasScale)
        let worldY = Float((screenPoint.y - canvasOffset.y) / canvasScale)
        let pad = Float(5.0 / canvasScale)

        for i in sim.nodes.indices.reversed() {
            let node = sim.nodes[i]
            let dx = worldX - node.position.x
            let dy = worldY - node.position.y
            let r = Float(node.radius) + pad
            if dx * dx + dy * dy <= r * r {
                return i
            }
        }
        return nil
    }

    // MARK: - Right-Click Context Menus (Nodes & Canvas)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let sim = simulation else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()

        if let idx = hitTestNode(at: location), idx < sim.nodes.count {
            contextMenuNodeIndex = idx
            let node = sim.nodes[idx]
            let tagName = node.tag.name
            let neighbors = sim.neighborIndices(of: idx)
            let isAlreadyFocused = (sim.focusedNodeIndex == idx)

            let headerItem = NSMenuItem(title: "#\(tagName) (\(node.tag.count ?? 0) items)", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            menu.addItem(.separator())

            if isAlreadyFocused {
                let releaseItem = NSMenuItem(
                    title: "Release Focus Ring",
                    action: #selector(ctxReleaseFocus),
                    keyEquivalent: ""
                )
                releaseItem.target = self
                releaseItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
                menu.addItem(releaseItem)
            } else {
                let focusItem = NSMenuItem(
                    title: "Focus #\(tagName) & 1st-Degree Ring (\(neighbors.count) connected)",
                    action: #selector(ctxFocusNode),
                    keyEquivalent: ""
                )
                focusItem.target = self
                focusItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
                menu.addItem(focusItem)
            }

            let selectItem = NSMenuItem(
                title: "Show #\(tagName) Stashes in Right Panel",
                action: #selector(ctxSelectNode),
                keyEquivalent: ""
            )
            selectItem.target = self
            selectItem.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
            menu.addItem(selectItem)

            let toggleItem = NSMenuItem(
                title: filterTags.contains(tagName) ? "Remove #\(tagName) from Selection" : "Add #\(tagName) to Selection",
                action: #selector(ctxToggleNodeSelection),
                keyEquivalent: ""
            )
            toggleItem.target = self
            toggleItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            menu.addItem(toggleItem)

            if !neighbors.isEmpty {
                let clusterItem = NSMenuItem(
                    title: "Select #\(tagName) + \(neighbors.count) Connected Tags",
                    action: #selector(ctxSelectNodeAndNeighbors),
                    keyEquivalent: ""
                )
                clusterItem.target = self
                clusterItem.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
                menu.addItem(clusterItem)
            }

            let openListItem = NSMenuItem(
                title: "Open #\(tagName) in Full List View",
                action: #selector(ctxOpenInListView),
                keyEquivalent: ""
            )
            openListItem.target = self
            openListItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
            menu.addItem(openListItem)

            menu.addItem(.separator())

            let renameItem = NSMenuItem(
                title: "Rename Tag…",
                action: #selector(ctxRenameTag),
                keyEquivalent: ""
            )
            renameItem.target = self
            renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(renameItem)

            let exportItem = NSMenuItem(
                title: "Export Tag…",
                action: #selector(ctxExportTag),
                keyEquivalent: ""
            )
            exportItem.target = self
            exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(exportItem)

            let copyItem = NSMenuItem(
                title: "Copy Tag Name",
                action: #selector(ctxCopyTagName),
                keyEquivalent: ""
            )
            copyItem.target = self
            copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(copyItem)
        } else {
            contextMenuNodeIndex = nil
            if sim.focusedNodeIndex != nil {
                let releaseItem = NSMenuItem(
                    title: "Release Focus Ring",
                    action: #selector(ctxReleaseFocus),
                    keyEquivalent: ""
                )
                releaseItem.target = self
                releaseItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
                menu.addItem(releaseItem)
            }

            if !filterTags.isEmpty {
                let clearSel = NSMenuItem(
                    title: "Clear Tag Selection",
                    action: #selector(ctxClearSelection),
                    keyEquivalent: ""
                )
                clearSel.target = self
                clearSel.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                menu.addItem(clearSel)
            }

            let resetCam = NSMenuItem(
                title: "Reset Zoom & Pan",
                action: #selector(ctxResetZoomAndPan),
                keyEquivalent: ""
            )
            resetCam.target = self
            resetCam.image = NSImage(systemSymbolName: "arrow.up.left.and.down.right.magnifyingglass", accessibilityDescription: nil)
            menu.addItem(resetCam)

            let relayout = NSMenuItem(
                title: "Re-run Force Layout",
                action: #selector(ctxRerunLayout),
                keyEquivalent: ""
            )
            relayout.target = self
            relayout.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            menu.addItem(relayout)
        }

        return menu
    }

    @objc private func ctxFocusNode() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        let tag = sim.nodes[idx].tag.name
        onEnsureSelectedTag?(tag)
        sim.focusNode(at: idx, canvasSize: bounds.size)
        onFocusChanged?(tag)
        syncSelectionAppearance()
    }

    @objc private func ctxReleaseFocus() {
        simulation?.clearFocus()
        onFocusChanged?(nil)
        syncSelectionAppearance()
    }

    @objc private func ctxSelectNode() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        onEnsureSelectedTag?(sim.nodes[idx].tag.name)
    }

    @objc private func ctxToggleNodeSelection() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        onSelectTag?(sim.nodes[idx].tag.name, true)
    }

    @objc private func ctxSelectNodeAndNeighbors() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        var names = [sim.nodes[idx].tag.name]
        for nIdx in sim.neighborIndices(of: idx) where nIdx < sim.nodes.count {
            names.append(sim.nodes[nIdx].tag.name)
        }
        onSelectTagAndNeighbors?(names)
    }

    @objc private func ctxOpenInListView() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        onOpenTagInList?(sim.nodes[idx].tag)
    }

    @objc private func ctxRenameTag() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        onRenameTag?(sim.nodes[idx].tag)
    }

    @objc private func ctxExportTag() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        onExportTag?(sim.nodes[idx].tag.name)
    }

    @objc private func ctxCopyTagName() {
        guard let idx = contextMenuNodeIndex, let sim = simulation, idx < sim.nodes.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sim.nodes[idx].tag.name, forType: .string)
    }

    @objc private func ctxClearSelection() {
        onClearSelection?()
    }

    @objc private func ctxResetZoomAndPan() {
        canvasScale = 1.0
        canvasOffset = .zero
        updateWorldTransform(animated: true)
    }

    @objc private func ctxRerunLayout() {
        guard let sim = simulation else { return }
        sim.clearFocus()
        onFocusChanged?(nil)
        sim.wake(ticks: 220)
    }
}

// MARK: - SIMD Vectorized Force Simulation + 1st-Degree Ring Focus

struct GraphNode {
    var tag: StashTag
    var position: simd_float2
    var velocity: simd_float2
    var radius: CGFloat

    var cgPosition: CGPoint {
        CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
    }
}

struct GraphEdgeRef {
    var sourceIndex: Int
    var targetIndex: Int
    var weight: Int
}

@MainActor
final class GraphSimulation: ObservableObject {
    var nodes: [GraphNode] = []
    var edges: [GraphEdgeRef] = []

    // Focus ring state (set on double-click or context menu "Focus")
    private(set) var focusedNodeIndex: Int?
    private(set) var focusedNeighborIndices: Set<Int> = []
    private(set) var focusRingTargets: [Int: simd_float2] = [:]
    private(set) var focusCenter: simd_float2 = .zero
    private(set) var focusRingRadius: CGFloat = 150

    var focusedTagName: String? {
        guard let idx = focusedNodeIndex, idx < nodes.count else { return nil }
        return nodes[idx].tag.name
    }

    var onStructureRebuilt: (() -> Void)?
    var onTick: (() -> Void)?
    var onCameraCenterRequest: ((CGPoint) -> Void)?

    private var timer: Timer?
    private var tick = 0
    private var totalTicks = 300
    private var lastCanvasSize: CGSize = CGSize(width: 800, height: 600)

    func setup(data: TagGraphData, canvasSize: CGSize) {
        timer?.invalidate()
        timer = nil
        if canvasSize.width > 10 && canvasSize.height > 10 {
            lastCanvasSize = canvasSize
        }

        let center = simd_float2(Float(lastCanvasSize.width / 2), Float(lastCanvasSize.height / 2))
        let maxCount = data.nodes.map { $0.count ?? 0 }.max() ?? 1
        let minR: CGFloat = 10
        let maxR: CGFloat = 35

        var nameToIndex: [String: Int] = [:]
        nodes = data.nodes.enumerated().map { i, tag in
            nameToIndex[tag.name] = i
            let r = minR + (maxR - minR) * sqrt(CGFloat(tag.count ?? 0) / CGFloat(max(maxCount, 1)))
            let angle = Float(i) / Float(max(data.nodes.count, 1)) * 2 * .pi
            let spread = Float(min(lastCanvasSize.width, lastCanvasSize.height) * 0.35)
            let pos = simd_float2(center.x + cos(angle) * spread, center.y + sin(angle) * spread)
            return GraphNode(tag: tag, position: pos, velocity: .zero, radius: r)
        }

        edges = data.edges.compactMap { edge in
            guard let si = nameToIndex[edge.tagA], let ti = nameToIndex[edge.tagB] else { return nil }
            return GraphEdgeRef(sourceIndex: si, targetIndex: ti, weight: edge.weight)
        }

        focusedNodeIndex = nil
        focusedNeighborIndices.removeAll()
        focusRingTargets.removeAll()

        for _ in 0..<80 {
            performStep(dtScale: 1.0)
        }

        onStructureRebuilt?()
        tick = 80
        startTimer()
    }

    func neighborIndices(of nodeIndex: Int) -> [Int] {
        var result: [(idx: Int, weight: Int)] = []
        for edge in edges {
            if edge.sourceIndex == nodeIndex {
                result.append((edge.targetIndex, edge.weight))
            } else if edge.targetIndex == nodeIndex {
                result.append((edge.sourceIndex, edge.weight))
            }
        }
        return result.sorted { $0.weight > $1.weight }.map(\.idx)
    }

    func focusNode(at nodeIndex: Int, canvasSize: CGSize) {
        guard nodeIndex >= 0 && nodeIndex < nodes.count else { return }
        if canvasSize.width > 10 && canvasSize.height > 10 {
            lastCanvasSize = canvasSize
        }

        let center = simd_float2(Float(lastCanvasSize.width / 2), Float(lastCanvasSize.height / 2))
        focusCenter = center
        focusedNodeIndex = nodeIndex

        let rawNeighbors = neighborIndices(of: nodeIndex)
        focusedNeighborIndices = Set(rawNeighbors)

        let currentNodePos = nodes[nodeIndex].position
        let sortedNeighbors = rawNeighbors.sorted { a, b in
            let da = nodes[a].position - currentNodePos
            let db = nodes[b].position - currentNodePos
            return atan2(da.y, da.x) < atan2(db.y, db.x)
        }

        let nCount = max(sortedNeighbors.count, 1)
        let ringR = Float(max(135.0, min(230.0, CGFloat(nCount) * 24.0)))
        focusRingRadius = CGFloat(ringR)

        focusRingTargets.removeAll(keepingCapacity: true)
        for (k, nIdx) in sortedNeighbors.enumerated() {
            let angle = (Float(k) / Float(nCount)) * (2.0 * .pi) - (.pi / 2.0)
            let target = simd_float2(center.x + cos(angle) * ringR, center.y + sin(angle) * ringR)
            focusRingTargets[nIdx] = target
        }

        let exclusionR = ringR + 125.0
        for i in nodes.indices {
            if i == nodeIndex {
                nodes[i].velocity = .zero
            } else if focusedNeighborIndices.contains(i) {
                nodes[i].velocity *= 0.2
            } else {
                var delta = nodes[i].position - center
                var dist = simd_length(delta)
                if dist < 1.0 {
                    let randAngle = Float.random(in: 0..<(2 * .pi))
                    delta = simd_float2(cos(randAngle), sin(randAngle))
                    dist = 1.0
                }
                if dist < exclusionR {
                    let dir = delta / dist
                    let push = (exclusionR - dist) * 0.35
                    nodes[i].velocity += dir * push
                }
            }
        }

        onCameraCenterRequest?(CGPoint(x: CGFloat(center.x), y: CGFloat(center.y)))
        wake(ticks: 180)
    }

    func clearFocus() {
        focusedNodeIndex = nil
        focusedNeighborIndices.removeAll()
        focusRingTargets.removeAll()
        wake(ticks: 140)
    }

    func wake(ticks: Int = 100) {
        guard !nodes.isEmpty else { return }
        tick = max(0, totalTicks - ticks)
        startTimer()
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

        let alpha = Float(max(0.02, 1.0 - Double(tick) / Double(totalTicks)))
        performStep(dtScale: alpha)
        onTick?()
    }

    private func performStep(dtScale: Float) {
        let repulsionK: Float = 3000.0
        let dt = dtScale
        let count = nodes.count
        guard count > 0 else { return }

        let maxDistSq: Float = 600.0 * 600.0
        for i in 0..<count {
            let posI = nodes[i].position
            for j in (i + 1)..<count {
                var delta = posI - nodes[j].position
                var distSq = simd_length_squared(delta)
                if distSq > maxDistSq { continue }
                if distSq < 1.0 {
                    delta = simd_float2(Float.random(in: -1...1), Float.random(in: -1...1))
                    distSq = 1.0
                }
                let invDist = 1.0 / sqrt(distSq)
                let force = (repulsionK * invDist * invDist) * dt
                let fVec = delta * (invDist * force)
                nodes[i].velocity += fVec
                nodes[j].velocity -= fVec
            }
        }

        for edge in edges {
            let i = edge.sourceIndex
            let j = edge.targetIndex
            guard i < count && j < count else { continue }
            let delta = nodes[j].position - nodes[i].position
            let dist = simd_length(delta)
            guard dist > 0.001 else { continue }

            let restLength: Float = 100.0 / sqrt(Float(max(edge.weight, 1)))
            let stiffness: Float = 0.05 * dt
            let force = (dist - restLength) * stiffness
            let fVec = (delta / dist) * force

            nodes[i].velocity += fVec
            nodes[j].velocity -= fVec
        }

        if let fIdx = focusedNodeIndex, fIdx < count {
            let toCenter = focusCenter - nodes[fIdx].position
            nodes[fIdx].position += toCenter * 0.28
            nodes[fIdx].velocity = .zero

            for (nIdx, target) in focusRingTargets where nIdx < count {
                let toTarget = target - nodes[nIdx].position
                nodes[nIdx].velocity += toTarget * 0.18
            }

            let exclusionR = Float(focusRingRadius) + 125.0
            for i in 0..<count where i != fIdx && !focusedNeighborIndices.contains(i) {
                var delta = nodes[i].position - focusCenter
                var dist = simd_length(delta)
                if dist < 1.0 {
                    delta = simd_float2(1, 0)
                    dist = 1.0
                }
                if dist < exclusionR {
                    let pushMag = (exclusionR - dist) * 0.22
                    nodes[i].velocity += (delta / dist) * pushMag
                }
            }
        } else {
            var sum = simd_float2.zero
            for i in 0..<count { sum += nodes[i].position }
            let avg = sum / Float(count)
            let pull = 0.005 * dt
            for i in 0..<count {
                nodes[i].velocity -= (nodes[i].position - avg) * pull
            }
        }

        let maxV: Float = 18.0
        let maxVSq = maxV * maxV
        for i in 0..<count {
            if i == focusedNodeIndex {
                nodes[i].velocity = .zero
                continue
            }
            nodes[i].velocity *= 0.84
            let vSq = simd_length_squared(nodes[i].velocity)
            if vSq > maxVSq {
                nodes[i].velocity *= (maxV / sqrt(vSq))
            }
            nodes[i].position += nodes[i].velocity
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
