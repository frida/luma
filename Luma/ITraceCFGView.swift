import AppKit
import Metal
import MetalKit
import SwiftUI

struct NodeRegisterInfo {
    let stateBeforeBlock: RegisterState   // state entering this block
    let stateAfterBlock: RegisterState    // state after all writes
    let writes: [RegisterWrite]           // writes within this block
}

struct ITraceCFGView: NSViewRepresentable {
    let graph: CFGGraph
    let currentSection: Int
    let blockBytes: [UInt64: Data]
    let nodeRegisterInfo: [CFGGraph.NodeKey: NodeRegisterInfo]
    let registerNames: [String]
    let disasmProvider: ((UInt64, Int) async -> String)?
    @Binding var selectedNodeKey: CFGGraph.NodeKey?
    var onNavigateFunction: ((Int) -> Void)?
    var onJumpToFunction: ((Int) -> Void)?  // absolute index: 0 = first, -1 = last
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> CFGContainerView {
        let container = CFGContainerView()

        let metalView = container.metalView
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)  // Updated in updateNSView

        context.coordinator.setup(device: metalView.device!, view: metalView)
        context.coordinator.container = container

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        container.addGestureRecognizer(click)

        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        container.addGestureRecognizer(pan)

        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        container.addGestureRecognizer(magnify)

        container.coordinator = context.coordinator

        // Auto-focus for keyboard input.
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(container)
        }

        return container
    }

    func updateNSView(_ container: CFGContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.disasmProvider = disasmProvider
        coordinator.blockBytes = blockBytes
        coordinator.nodeRegisterInfo = nodeRegisterInfo
        coordinator.registerNames = registerNames
        coordinator.currentSection = currentSection
        coordinator.isDarkMode = colorScheme == .dark
        coordinator.onNavigateFunction = onNavigateFunction
        coordinator.onJumpToFunction = onJumpToFunction

        let graphChanged = coordinator.graph.entryKey != graph.entryKey
            || coordinator.graph.nodes.count != graph.nodes.count
        let isFirstLoad = coordinator.graph.nodes.isEmpty
        if graphChanged {
            // Remember selected node position before rebuild.
            let anchorKey = coordinator.selectedKey
            let oldAnchorPos = anchorKey.flatMap { coordinator.graph.nodes[$0]?.position }

            coordinator.graph = graph

            let nodes = coordinator.graph.nodes
            coordinator.graph.assignPositions { key in
                coordinator.nodeHeight(for: nodes[key]!)
            }

            if isFirstLoad || coordinator.pendingFitAlignment != nil {
                let alignment = coordinator.pendingFitAlignment ?? .leading
                coordinator.pendingFitAlignment = nil
                coordinator.fitToView(alignment: alignment)

                if isFirstLoad {
                    let first = coordinator.graph.nodes.values
                        .filter { $0.section == coordinator.currentSection }
                        .min(by: { $0.position.y < $1.position.y })
                    if let first {
                        coordinator.select(first.key)
                    }
                }
            } else if let oldPos = oldAnchorPos,
                let newPos = anchorKey.flatMap({ coordinator.graph.nodes[$0]?.position })
            {
                // Only compensate X. Y is managed by pendingNav/panToNode.
                coordinator.camera.offset.x -= (newPos.x - oldPos.x) * coordinator.camera.zoom
            }

            coordinator.fetchDisasmForVisibleNodes()
        }

        if let nav = coordinator.pendingNav {
            let sectionNodes = coordinator.graph.nodes.values
                .filter { $0.section == coordinator.currentSection }
                .sorted { $0.position.y < $1.position.y }
            if let node = (nav.direction < 0 ? sectionNodes.last : sectionNodes.first) {
                coordinator.pendingNav = nil
                coordinator.select(node.key)

                // Ensure the node is visible, then align Y to section top.
                coordinator.panToNode(node, axis: .both)
                if nav.axis == .horizontal {
                    let viewSize = container.bounds.size
                    let section = coordinator.sectionBounds(coordinator.currentSection)
                    let margin: CGFloat = 20
                    coordinator.camera.offset.y = margin - section.minY * coordinator.camera.zoom - viewSize.height / 2
                }
            }
            // If no nodes found for the section, keep pendingNav
            // until the graph rebuilds with the right data.
        } else if selectedNodeKey != coordinator.selectedKey {
            coordinator.selectedKey = selectedNodeKey
            if let key = selectedNodeKey, let node = coordinator.graph.nodes[key] {
                coordinator.panToNode(node, axis: .both)
            }
        }

        container.metalView.clearColor = coordinator.isDarkMode
            ? MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
            : MTLClearColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        container.metalView.needsDisplay = true
        container.textOverlay.isDarkMode = coordinator.isDarkMode
        container.textOverlay.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedNodeKey: $selectedNodeKey)
    }
}

// MARK: - Container View

class CFGContainerView: NSView {
    let metalView = MTKView()
    let textOverlay = CFGTextOverlayView()
    weak var coordinator: ITraceCFGView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 123:  // left arrow
            coordinator.pendingNav = (direction: 1, axis: .both)
            coordinator.onNavigateFunction?(-1)
        case 124:  // right arrow
            coordinator.pendingNav = (direction: 1, axis: .both)
            coordinator.onNavigateFunction?(1)
        case 125:  // down arrow
            coordinator.moveDown()
        case 126:  // up arrow
            coordinator.moveUp()
        case 36:  // Return
            coordinator.showRegisterPopover()
        case 53:  // Escape
            coordinator.dismissRegisterPopover()
        default:
            if let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "\u{F729}":  // Home
                    coordinator.selectFirstNode()
                case "\u{F72B}":  // End
                    coordinator.selectLastNode()
                case "\u{F72C}":  // Page Up
                    coordinator.jumpToPreviousBlock()
                case "\u{F72D}":  // Page Down
                    coordinator.jumpToNextBlock()
                default:
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = true

        metalView.translatesAutoresizingMaskIntoConstraints = false
        textOverlay.translatesAutoresizingMaskIntoConstraints = false

        addSubview(metalView)
        addSubview(textOverlay)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            textOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            textOverlay.topAnchor.constraint(equalTo: topAnchor),
            textOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - Text Overlay

class CFGTextOverlayView: NSView {
    struct NodeLabel {
        let worldRect: CGRect
        let name: String
        let cachedDisasm: NSAttributedString?
        let isSelected: Bool
        let selectedLine: Int?  // instruction line within this node, if selected
    }

    let disasmFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)

    var labels: [NodeLabel] = []
    var cameraOffset: CGPoint = .zero
    var cameraZoom: CGFloat = 1.0
    var isDarkMode: Bool = true

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let viewSize = bounds.size
        let viewBounds = bounds

        ctx.saveGState()

        // Apply camera transform: translate to center, then zoom + pan.
        ctx.translateBy(x: viewSize.width / 2 + cameraOffset.x, y: viewSize.height / 2 + cameraOffset.y)
        ctx.scaleBy(x: cameraZoom, y: cameraZoom)

        let nameFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let padding: CGFloat = 4
        let nameHeight: CGFloat = 16

        for label in labels {
            let screenRect = CGRect(
                x: label.worldRect.minX * cameraZoom + viewSize.width / 2 + cameraOffset.x,
                y: label.worldRect.minY * cameraZoom + viewSize.height / 2 + cameraOffset.y,
                width: label.worldRect.width * cameraZoom,
                height: label.worldRect.height * cameraZoom
            )
            guard screenRect.intersects(viewBounds) else { continue }

            ctx.saveGState()
            ctx.clip(to: label.worldRect)

            let nameColor: NSColor = label.isSelected
                ? (isDarkMode ? .white : .white)
                : (isDarkMode ? NSColor(calibratedRed: 0.6, green: 0.85, blue: 1.0, alpha: 1.0)
                              : NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.7, alpha: 1.0))
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: nameFont,
                .foregroundColor: nameColor,
            ]
            let nameStr = NSAttributedString(string: shortName(label.name), attributes: nameAttrs)
            let nameRect = CGRect(
                x: label.worldRect.minX + padding,
                y: label.worldRect.minY + 2,
                width: 10000,
                height: nameHeight
            )
            nameStr.draw(with: nameRect, options: [.usesLineFragmentOrigin])

            if let disasm = label.cachedDisasm {
                let disasmY = label.worldRect.minY + nameHeight + 2
                let lineH = ceil(disasmFont.ascender - disasmFont.descender + disasmFont.leading)

                // Highlight selected instruction line.
                if let line = label.selectedLine {
                    let highlightY = disasmY + CGFloat(line) * lineH
                    let highlightRect = CGRect(
                        x: label.worldRect.minX,
                        y: highlightY,
                        width: label.worldRect.width,
                        height: lineH
                    )
                    let highlightColor = isDarkMode
                        ? NSColor.white.withAlphaComponent(0.1)
                        : NSColor.black.withAlphaComponent(0.08)
                    highlightColor.setFill()
                    NSBezierPath.fill(highlightRect)
                }

                let disasmRect = CGRect(
                    x: label.worldRect.minX + padding,
                    y: disasmY,
                    width: 10000,
                    height: label.worldRect.height - nameHeight - 4
                )
                disasm.draw(with: disasmRect, options: [.usesLineFragmentOrigin])
            }

            ctx.restoreGState()
        }

        ctx.restoreGState()
    }

    private func shortName(_ name: String) -> String {
        if let bangIdx = name.firstIndex(of: "!") {
            return String(name[name.index(after: bangIdx)...])
        }
        return name
    }
}

// MARK: - Coordinator

extension ITraceCFGView {

    class Coordinator: NSObject, MTKViewDelegate {
        var graph: CFGGraph = CFGGraph(nodes: [:], edges: [], entryKey: 0)
        var selectedKey: CFGGraph.NodeKey?
        var selectedInstructionLine: Int = 0  // line index within selected node's disasm
        var disasmProvider: ((UInt64, Int) async -> String)?
        var blockBytes: [UInt64: Data] = [:]
        var nodeRegisterInfo: [CFGGraph.NodeKey: NodeRegisterInfo] = [:]
        var registerNames: [String] = []
        var currentSection: Int = 0
        var isDarkMode: Bool = true
        var onNavigateFunction: ((Int) -> Void)?
        var onJumpToFunction: ((Int) -> Void)?
        var pendingNav: (direction: Int, axis: PanAxis)?
        enum FitAlignment { case leading, trailing }
        var pendingFitAlignment: FitAlignment?
        var needsInitialFit = true
        weak var container: CFGContainerView?

        var selectedBinding: Binding<CFGGraph.NodeKey?>
        private var disasmRaw: [UInt64: String] = [:]
        private var disasmRendered: [UInt64: NSAttributedString] = [:]
        private var nodeHeightCache: [UInt64: CGFloat] = [:]
        private var fetchTask: Task<Void, Never>?

        private var device: MTLDevice!
        private var commandQueue: MTLCommandQueue!
        private var pipelineState: MTLRenderPipelineState!

        var camera = Camera()

        struct Camera {
            var offset: CGPoint = .zero
            var zoom: CGFloat = 1.0
        }

        struct Vertex {
            var position: SIMD2<Float>
            var color: SIMD4<Float>
        }

        private let nodeWidth: CGFloat = 360
        private let nodeBaseHeight: CGFloat = 18
        private let disasmFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)

        init(selectedNodeKey: Binding<CFGGraph.NodeKey?>) {
            self.selectedBinding = selectedNodeKey
        }

        func setup(device: MTLDevice, view: MTKView) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            let library = try! device.makeDefaultLibrary(bundle: Bundle.main)

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "cfgVertexShader")
            desc.fragmentFunction = library.makeFunction(name: "cfgFragmentShader")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

            pipelineState = try! device.makeRenderPipelineState(descriptor: desc)
        }

        private let titleHeight: CGFloat = 16

        func nodeHeight(for node: CFGGraph.Node) -> CGFloat {
            if let cached = nodeHeightCache[node.address] { return cached }

            let h: CGFloat
            if let rendered = disasmRendered[node.address] {
                let lineCount = rendered.string.components(separatedBy: "\n").count
                let lineH = ceil(disasmFont.ascender - disasmFont.descender + disasmFont.leading)
                h = titleHeight + CGFloat(max(1, lineCount)) * lineH + 4
            } else {
                h = titleHeight + ceil(disasmFont.ascender - disasmFont.descender + disasmFont.leading) + 4
            }

            nodeHeightCache[node.address] = h
            return h
        }

        func fetchDisasmForVisibleNodes() {
            var toFetch: [(UInt64, Int)] = []
            for (_, node) in graph.nodes {
                let addr = node.address
                guard disasmRaw[addr] == nil else { continue }
                let size = blockBytes[addr]?.count ?? node.size
                toFetch.append((addr, size))
            }

            guard !toFetch.isEmpty, let provider = disasmProvider else { return }

            // Cancel any in-flight fetch to prevent concurrent relayouts.
            fetchTask?.cancel()
            fetchTask = Task { @MainActor in
                for (addr, size) in toFetch {
                    guard !Task.isCancelled else { return }
                    guard self.disasmRaw[addr] == nil else { continue }
                    var result = await provider(addr, size)
                    while result.hasSuffix("\n") { result.removeLast() }
                    self.disasmRaw[addr] = result
                    self.disasmRendered[addr] = self.renderDisasm(result)
                    self.nodeHeightCache.removeValue(forKey: addr)
                }

                guard !Task.isCancelled else { return }

                // Remember selected node position before relayout.
                let anchorNode = self.selectedKey.flatMap { self.graph.nodes[$0] }
                let oldAnchorPos = anchorNode?.position

                let nodes = self.graph.nodes
                self.graph.assignPositions { key in
                    self.nodeHeight(for: nodes[key]!)
                }

                // Compensate both axes — content shifted due to height changes.
                if let oldPos = oldAnchorPos,
                    let newPos = self.selectedKey.flatMap({ self.graph.nodes[$0]?.position })
                {
                    self.camera.offset.x -= (newPos.x - oldPos.x) * self.camera.zoom
                    self.camera.offset.y -= (newPos.y - oldPos.y) * self.camera.zoom
                }

                if self.needsInitialFit {
                    self.needsInitialFit = false
                    self.fitToView()
                } else {
                    self.container?.metalView.needsDisplay = true
                    self.container?.textOverlay.needsDisplay = true
                }
            }
        }

        private func renderDisasm(_ raw: String) -> NSAttributedString {
            parseAnsiToNSAttributedString(raw, font: disasmFont)
        }

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                let descriptor = view.currentRenderPassDescriptor
            else { return }

            let viewSize = view.bounds.size
            var vertices: [Vertex] = []

            func worldToScreen(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: point.x * camera.zoom + viewSize.width / 2 + camera.offset.x,
                    y: point.y * camera.zoom + viewSize.height / 2 + camera.offset.y
                )
            }

            func toNDC(_ screen: CGPoint) -> SIMD2<Float> {
                SIMD2<Float>(
                    Float(screen.x / viewSize.width * 2 - 1),
                    Float(1 - screen.y / viewSize.height * 2)
                )
            }

            // Viewport for culling.
            let viewBounds = CGRect(origin: .zero, size: viewSize)
            let cullMargin: CGFloat = 100
            let cullRect = viewBounds.insetBy(dx: -cullMargin, dy: -cullMargin)

            // Draw edges.
            let maxCount = graph.edges.lazy.map(\.count).max() ?? 1

            for edge in graph.edges {
                guard let fromNode = graph.nodes[edge.from],
                    let toNode = graph.nodes[edge.to]
                else { continue }

                let intensity = Float(edge.count) / Float(maxCount)
                let color: SIMD4<Float>
                if edge.isCrossSection {
                    color = isDarkMode
                        ? SIMD4(1.0, 0.7, 0.3, 0.6)
                        : SIMD4(0.8, 0.5, 0.1, 0.6)
                } else {
                    color = isDarkMode
                        ? SIMD4(0.4, 0.6 + 0.4 * intensity, 1.0, 0.3 + 0.5 * intensity)
                        : SIMD4(0.2, 0.3 + 0.3 * intensity, 0.8, 0.4 + 0.4 * intensity)
                }

                let fromH = nodeHeight(for: fromNode)
                let toH = nodeHeight(for: toNode)

                let fromScreen = worldToScreen(CGPoint(x: fromNode.position.x, y: fromNode.position.y + fromH / 2))
                let toScreen = worldToScreen(CGPoint(x: toNode.position.x, y: toNode.position.y - toH / 2))

                guard cullRect.contains(fromScreen) || cullRect.contains(toScreen) else { continue }

                let from = toNDC(fromScreen)
                let to = toNDC(toScreen)

                let dx = to.x - from.x
                let dy = to.y - from.y
                let len = sqrt(dx * dx + dy * dy)
                guard len > 0 else { continue }
                let lineWidth: Float = 1.5 / Float(viewSize.width)
                let nx = -dy / len * lineWidth
                let ny = dx / len * lineWidth

                vertices.append(Vertex(position: from + SIMD2(nx, ny), color: color))
                vertices.append(Vertex(position: from - SIMD2(nx, ny), color: color))
                vertices.append(Vertex(position: to + SIMD2(nx, ny), color: color))
                vertices.append(Vertex(position: to - SIMD2(nx, ny), color: color))
                vertices.append(Vertex(position: to + SIMD2(nx, ny), color: color))
                vertices.append(Vertex(position: from - SIMD2(nx, ny), color: color))

                // Arrow head.
                let arrowPx: Float = 8 / Float(viewSize.width)
                let tip = to
                let left = to - SIMD2(dx / len * arrowPx * 2 - ny * arrowPx, dy / len * arrowPx * 2 + nx * arrowPx)
                let right = to - SIMD2(dx / len * arrowPx * 2 + ny * arrowPx, dy / len * arrowPx * 2 - nx * arrowPx)
                vertices.append(Vertex(position: tip, color: color))
                vertices.append(Vertex(position: left, color: color))
                vertices.append(Vertex(position: right, color: color))
            }

            // Draw node backgrounds and collect text overlay labels.
            var textLabels: [CFGTextOverlayView.NodeLabel] = []

            for (_, node) in graph.nodes {
                let isSelected = node.key == selectedKey
                let h = nodeHeight(for: node)

                let topLeft = worldToScreen(CGPoint(x: node.position.x - nodeWidth / 2, y: node.position.y - h / 2))
                let bottomRight = worldToScreen(CGPoint(x: node.position.x + nodeWidth / 2, y: node.position.y + h / 2))

                let nodeScreenRect = CGRect(
                    x: topLeft.x, y: topLeft.y,
                    width: bottomRight.x - topLeft.x,
                    height: bottomRight.y - topLeft.y
                )
                guard nodeScreenRect.intersects(viewBounds) else { continue }

                let baseColor: SIMD4<Float>
                if isDarkMode {
                    baseColor = isSelected ? SIMD4(0.2, 0.45, 0.7, 0.9) : SIMD4(0.15, 0.18, 0.25, 0.85)
                } else {
                    baseColor = isSelected ? SIMD4(0.7, 0.85, 1.0, 0.95) : SIMD4(1.0, 1.0, 1.0, 0.95)
                }

                let tl = toNDC(topLeft)
                let br = toNDC(bottomRight)
                let tr = SIMD2<Float>(br.x, tl.y)
                let bl = SIMD2<Float>(tl.x, br.y)

                vertices.append(Vertex(position: tl, color: baseColor))
                vertices.append(Vertex(position: tr, color: baseColor))
                vertices.append(Vertex(position: bl, color: baseColor))
                vertices.append(Vertex(position: tr, color: baseColor))
                vertices.append(Vertex(position: br, color: baseColor))
                vertices.append(Vertex(position: bl, color: baseColor))

                // Border.
                let borderColor: SIMD4<Float>
                if isDarkMode {
                    borderColor = isSelected ? SIMD4(0.4, 0.7, 1.0, 1.0) : SIMD4(0.3, 0.4, 0.5, 0.6)
                } else {
                    borderColor = isSelected ? SIMD4(0.2, 0.5, 0.9, 1.0) : SIMD4(0.7, 0.75, 0.8, 0.8)
                }
                let bh: Float = 1 / Float(viewSize.height)

                // Top
                vertices.append(Vertex(position: tl, color: borderColor))
                vertices.append(Vertex(position: tr, color: borderColor))
                vertices.append(Vertex(position: SIMD2(tl.x, tl.y - bh), color: borderColor))
                vertices.append(Vertex(position: tr, color: borderColor))
                vertices.append(Vertex(position: SIMD2(tr.x, tr.y - bh), color: borderColor))
                vertices.append(Vertex(position: SIMD2(tl.x, tl.y - bh), color: borderColor))

                // Collect label for text overlay (in world coordinates).
                let worldRect = CGRect(
                    x: node.position.x - nodeWidth / 2,
                    y: node.position.y - h / 2,
                    width: nodeWidth,
                    height: h
                )
                textLabels.append(CFGTextOverlayView.NodeLabel(
                    worldRect: worldRect,
                    name: node.name,
                    cachedDisasm: disasmRendered[node.address],
                    isSelected: isSelected,
                    selectedLine: isSelected ? selectedInstructionLine : nil
                ))
            }

            // Update text overlay.
            if let overlay = container?.textOverlay {
                overlay.labels = textLabels
                overlay.cameraOffset = camera.offset
                overlay.cameraZoom = camera.zoom
                overlay.needsDisplay = true
            }

            guard !vertices.isEmpty else { return }

            let buffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<Vertex>.stride,
                options: .storageModeShared
            )

            let commandBuffer = commandQueue.makeCommandBuffer()!
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Gestures

        private var panStarted = false

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)

            if gesture.state == .began {
                panStarted = false
            }

            // Require a minimum drag before panning, so small movements
            // during a click don't hijack the interaction.
            if !panStarted {
                if abs(translation.x) < 3 && abs(translation.y) < 3 {
                    return
                }
                panStarted = true
            }

            camera.offset.x += translation.x
            camera.offset.y -= translation.y
            gesture.setTranslation(.zero, in: gesture.view)
            clampCamera()
            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            camera.zoom *= 1 + gesture.magnification
            let minZoom = computeFitZoom() * 0.9
            camera.zoom = max(minZoom, min(3, camera.zoom))
            gesture.magnification = 0
            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
            clampCamera()
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view else { return }
            view.window?.makeFirstResponder(view)
            let raw = gesture.location(in: view)
            let viewSize = view.bounds.size
            let loc = CGPoint(x: raw.x, y: viewSize.height - raw.y)

            let worldX = (loc.x - viewSize.width / 2 - camera.offset.x) / camera.zoom
            let worldY = (loc.y - viewSize.height / 2 - camera.offset.y) / camera.zoom

            var bestKey: CFGGraph.NodeKey?
            var bestDist: CGFloat = .greatestFiniteMagnitude

            for (_, node) in graph.nodes {
                let h = nodeHeight(for: node)
                let dx = CGFloat(node.position.x) - worldX
                let dy = CGFloat(node.position.y) - worldY
                let dist = dx * dx + dy * dy
                if dist < bestDist && abs(dx) < nodeWidth / 2 && abs(dy) < h / 2 {
                    bestDist = dist
                    bestKey = node.key
                }
            }

            // Compute which instruction line was clicked.
            var clickedLine = 0
            if let key = bestKey, let node = graph.nodes[key] {
                let nodeTop = node.position.y - nodeHeight(for: node) / 2
                let disasmY = nodeTop + titleHeight + 2
                let lineH = ceil(disasmFont.ascender - disasmFont.descender + disasmFont.leading)
                let relY = worldY - disasmY
                if relY > 0, lineH > 0 {
                    clickedLine = max(0, min(instructionCount(for: node) - 1, Int(relY / lineH)))
                }
            }

            select(bestKey, line: clickedLine)

            if let key = bestKey, let node = graph.nodes[key], node.section != currentSection {
                onJumpToFunction?(node.section)
            }

            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }

        // MARK: - Keyboard Navigation

        func select(_ key: CFGGraph.NodeKey?, line: Int = 0) {
            selectedKey = key
            selectedInstructionLine = line
            selectedBinding.wrappedValue = key
        }

        private var popover: NSPopover?

        func showRegisterPopover() {
            guard let key = selectedKey, let node = graph.nodes[key],
                let info = nodeRegisterInfo[key],
                let viewSize = container?.bounds.size
            else { return }

            dismissRegisterPopover()

            // Compute state at the selected instruction.
            // On arm64 each instruction is 4 bytes.
            let instrOffset = selectedInstructionLine * 4
            var values = info.stateBeforeBlock.values
            var changed = Set<Int>()
            for write in info.writes where write.blockOffset <= instrOffset {
                values[write.registerIndex] = write.value
                if write.blockOffset == instrOffset {
                    changed.insert(write.registerIndex)
                }
            }

            // Build popover content.
            let content = NSMutableAttributedString()
            let normalAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let changedAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: 1.0),
            ]

            let sorted = values.keys.sorted()
            for idx in sorted {
                guard idx < registerNames.count else { continue }
                let name = registerNames[idx]
                let value = values[idx]!
                let attrs = changed.contains(idx) ? changedAttrs : normalAttrs
                let line = String(format: "%-5s 0x%016llx\n", (name as NSString).utf8String!, value)
                content.append(NSAttributedString(string: line, attributes: attrs))
            }

            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
            textView.isEditable = false
            textView.drawsBackground = false
            textView.textStorage?.setAttributedString(content)
            textView.sizeToFit()

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: min(400, textView.frame.height + 16)))
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false

            let vc = NSViewController()
            vc.view = scrollView

            let pop = NSPopover()
            pop.contentViewController = vc
            pop.behavior = .transient

            // Position at the selected instruction line.
            let titleHeight: CGFloat = 16
            let lineH = ceil(disasmFont.ascender - disasmFont.descender + disasmFont.leading)
            let instrWorldY = node.position.y - nodeHeight(for: node) / 2 + titleHeight + 2 + CGFloat(selectedInstructionLine) * lineH + lineH / 2

            let screenX = node.position.x * camera.zoom + viewSize.width / 2 + camera.offset.x
            let screenY = instrWorldY * camera.zoom + viewSize.height / 2 + camera.offset.y

            if let containerView = container {
                let rect = NSRect(x: screenX + nodeWidth / 2 * camera.zoom, y: containerView.bounds.height - screenY - 5, width: 1, height: 10)
                pop.show(relativeTo: rect, of: containerView, preferredEdge: .maxX)
                self.popover = pop
            }
        }

        func dismissRegisterPopover() {
            popover?.close()
            popover = nil
        }

        func instructionCount(for node: CFGGraph.Node) -> Int {
            disasmRendered[node.address].map {
                $0.string.components(separatedBy: "\n").count
            } ?? 0
        }

        func selectFirstNode() {
            pendingNav = (direction: 1, axis: .both)
            pendingFitAlignment = .leading
            onJumpToFunction?(0)
        }

        func selectLastNode() {
            pendingNav = (direction: -1, axis: .both)
            pendingFitAlignment = .trailing
            onJumpToFunction?(-1)
        }

        func jumpToNextBlock() {
            let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
            selectNextIn(sorted, direction: 1)
        }

        func jumpToPreviousBlock() {
            let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
            selectNextIn(sorted, direction: -1)
        }

        func moveDown() {
            // Try moving to the next instruction within the current node.
            if let key = selectedKey, let node = graph.nodes[key] {
                let count = instructionCount(for: node)
                if selectedInstructionLine + 1 < count {
                    selectedInstructionLine += 1
                    container?.metalView.needsDisplay = true
                    container?.textOverlay.needsDisplay = true
                    return
                }
            }
            // At the last instruction — move to the next node.
            let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
            selectNextIn(sorted, direction: 1)
        }

        func moveUp() {
            if selectedInstructionLine > 0 {
                selectedInstructionLine -= 1
                container?.metalView.needsDisplay = true
                container?.textOverlay.needsDisplay = true
                return
            }
            // At the first instruction — move to the previous node's last instruction.
            let sorted = currentSectionNodes().sorted { $0.position.y < $1.position.y }
            selectNextIn(sorted, direction: -1)
        }

        private func computeFitZoom() -> CGFloat {
            guard let viewSize = container?.bounds.size,
                viewSize.width > 0, viewSize.height > 0
            else { return 1.0 }

            let bounds = sectionBounds(currentSection)
            guard bounds.width > 0, bounds.height > 0 else { return 1.0 }

            let margin: CGFloat = 20
            let zoomX = (viewSize.width - margin * 2) / bounds.width
            let zoomY = (viewSize.height - margin * 2) / bounds.height
            return min(zoomX, zoomY, 1.0)
        }

        func fitToView(alignment: FitAlignment = .leading) {
            guard let viewSize = container?.bounds.size else { return }
            camera.zoom = computeFitZoom()

            let section = sectionBounds(currentSection)
            let margin: CGFloat = 20
            let hw = viewSize.width / 2
            let hh = viewSize.height / 2

            let x: CGFloat
            switch alignment {
            case .leading:
                x = margin - section.minX * camera.zoom - hw
            case .trailing:
                x = (viewSize.width - margin) - section.maxX * camera.zoom - hw
            }

            camera.offset = CGPoint(x: x, y: margin - section.minY * camera.zoom - hh)

            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }

        func clampCamera() {
            guard let viewSize = container?.bounds.size else { return }
            let content = allNodesBounds()
            guard content.width > 0 else { return }

            let margin: CGFloat = 20
            let hw = viewSize.width / 2
            let hh = viewSize.height / 2

            // worldToScreen: screen = world * zoom + viewSize/2 + offset
            // Content left edge at screen `margin`:
            //   margin = content.minX * zoom + hw + offset.x
            //   offset.x = margin - content.minX * zoom - hw
            let maxOffsetX = margin - content.minX * camera.zoom - hw
            // Content right edge at screen `viewSize.width - margin`:
            let minOffsetX = (viewSize.width - margin) - content.maxX * camera.zoom - hw
            // Content top edge at screen `margin`:
            let maxOffsetY = margin - content.minY * camera.zoom - hh
            // Content bottom edge at screen `viewSize.height - margin`:
            let minOffsetY = (viewSize.height - margin) - content.maxY * camera.zoom - hh

            camera.offset.x = max(minOffsetX, min(maxOffsetX, camera.offset.x))
            camera.offset.y = max(minOffsetY, min(maxOffsetY, camera.offset.y))
        }

        func sectionBounds(_ section: Int) -> CGRect {
            let sectionNodes = graph.nodes.values.filter { $0.section == section }
            guard !sectionNodes.isEmpty else {
                // Fall back to all nodes.
                return allNodesBounds()
            }
            return boundingRect(of: sectionNodes)
        }

        private func allNodesBounds() -> CGRect {
            boundingRect(of: Array(graph.nodes.values))
        }

        private func boundingRect(of nodes: [CFGGraph.Node]) -> CGRect {
            guard !nodes.isEmpty else { return .zero }

            var minX: CGFloat = .greatestFiniteMagnitude
            var maxX: CGFloat = -.greatestFiniteMagnitude
            var minY: CGFloat = .greatestFiniteMagnitude
            var maxY: CGFloat = -.greatestFiniteMagnitude

            for node in nodes {
                let h = nodeHeight(for: node)
                minX = min(minX, node.position.x - nodeWidth / 2)
                maxX = max(maxX, node.position.x + nodeWidth / 2)
                minY = min(minY, node.position.y - h / 2)
                maxY = max(maxY, node.position.y + h / 2)
            }

            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        enum PanAxis { case both, horizontal, vertical }

        func panToNode(_ node: CFGGraph.Node, axis: PanAxis = .both) {
            guard let viewSize = container?.bounds.size else { return }

            let screenX = node.position.x * camera.zoom + viewSize.width / 2 + camera.offset.x
            let screenY = node.position.y * camera.zoom + viewSize.height / 2 + camera.offset.y
            let halfW = nodeWidth / 2 * camera.zoom
            let halfH = nodeHeight(for: node) / 2 * camera.zoom

            let margin: CGFloat = 20
            var dx: CGFloat = 0
            var dy: CGFloat = 0

            if axis != .vertical {
                if screenX - halfW < margin {
                    dx = margin - (screenX - halfW)
                } else if screenX + halfW > viewSize.width - margin {
                    dx = (viewSize.width - margin) - (screenX + halfW)
                }
            }

            if axis != .horizontal {
                if screenY - halfH < margin {
                    dy = margin - (screenY - halfH)
                } else if screenY + halfH > viewSize.height - margin {
                    dy = (viewSize.height - margin) - (screenY + halfH)
                }
            }

            if dx != 0 || dy != 0 {
                camera.offset.x += dx
                camera.offset.y += dy
            }
        }

        private func currentSectionNodes() -> [CFGGraph.Node] {
            let current = graph.nodes.values.filter { $0.section == currentSection }
            return current.isEmpty ? Array(graph.nodes.values) : current
        }

        private func selectNextIn(_ sorted: [CFGGraph.Node], direction: Int) {
            guard !sorted.isEmpty else { return }

            let currentIdx = sorted.firstIndex { $0.key == selectedKey }
            let nextIdx: Int
            if let currentIdx {
                let candidate = currentIdx + direction
                if candidate < 0 || candidate >= sorted.count {
                    pendingNav = (direction: direction, axis: .both)
                    onNavigateFunction?(direction)
                    return
                }
                nextIdx = candidate
            } else {
                nextIdx = direction > 0 ? 0 : sorted.count - 1
            }

            let node = sorted[nextIdx]
            let line = direction > 0 ? 0 : max(0, instructionCount(for: node) - 1)
            select(node.key, line: line)
            panToNode(node, axis: .vertical)
            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }
    }
}

