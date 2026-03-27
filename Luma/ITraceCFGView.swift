import AppKit
import Metal
import MetalKit
import SwiftUI

struct ITraceCFGView: NSViewRepresentable {
    let graph: CFGGraph
    let blockBytes: [UInt64: Data]
    let disasmProvider: ((UInt64, Int) async -> String)?
    @Binding var selectedAddress: UInt64?
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

        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        container.addGestureRecognizer(pan)

        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        container.addGestureRecognizer(magnify)

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        container.addGestureRecognizer(click)

        return container
    }

    func updateNSView(_ container: CFGContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.graph = graph
        coordinator.selectedAddress = selectedAddress
        coordinator.disasmProvider = disasmProvider
        coordinator.blockBytes = blockBytes
        coordinator.isDarkMode = colorScheme == .dark
        coordinator.fetchDisasmForVisibleNodes()

        if coordinator.isDarkMode {
            container.metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        } else {
            container.metalView.clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        }

        container.metalView.needsDisplay = true
        container.textOverlay.isDarkMode = coordinator.isDarkMode
        container.textOverlay.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedAddress: $selectedAddress)
    }
}

// MARK: - Container View

class CFGContainerView: NSView {
    let metalView = MTKView()
    let textOverlay = CFGTextOverlayView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
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
        let worldRect: CGRect      // In world coordinates (unscaled)
        let name: String
        let cachedDisasm: NSAttributedString?
        let isSelected: Bool
    }

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
        let nameHeight: CGFloat = 14

        for label in labels {
            let screenRect = CGRect(
                x: label.worldRect.minX * cameraZoom + viewSize.width / 2 + cameraOffset.x,
                y: label.worldRect.minY * cameraZoom + viewSize.height / 2 + cameraOffset.y,
                width: label.worldRect.width * cameraZoom,
                height: label.worldRect.height * cameraZoom
            )
            guard screenRect.intersects(viewBounds) else { continue }

            // Skip text when nodes are too small to read.
            guard screenRect.height > 16 else { continue }

            ctx.saveGState()
            ctx.clip(to: label.worldRect)

            // Draw name if there's enough room.
            if screenRect.height > 12 {
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
            }

            // Draw disasm only when zoomed in enough to read it.
            if screenRect.height > 40, let disasm = label.cachedDisasm {
                let disasmRect = CGRect(
                    x: label.worldRect.minX + padding,
                    y: label.worldRect.minY + nameHeight + 2,
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
        var graph: CFGGraph = CFGGraph(nodes: [:], edges: [], entryAddress: 0)
        var selectedAddress: UInt64?
        var disasmProvider: ((UInt64, Int) async -> String)?
        var blockBytes: [UInt64: Data] = [:]
        var isDarkMode: Bool = true
        weak var container: CFGContainerView?

        private var selectedBinding: Binding<UInt64?>
        private var disasmRaw: [UInt64: String] = [:]
        private var disasmRendered: [UInt64: NSAttributedString] = [:]
        private var nodeHeightCache: [UInt64: CGFloat] = [:]
        private var layoutDebounce: Task<Void, Never>?

        private var device: MTLDevice!
        private var commandQueue: MTLCommandQueue!
        private var pipelineState: MTLRenderPipelineState!

        private var camera = Camera()

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

        init(selectedAddress: Binding<UInt64?>) {
            self.selectedBinding = selectedAddress
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

        func nodeHeight(for node: CFGGraph.Node) -> CGFloat {
            if let cached = nodeHeightCache[node.address] { return cached }

            let h: CGFloat
            if let rendered = disasmRendered[node.address] {
                let textHeight = rendered.boundingRect(
                    with: CGSize(width: 10000, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin]
                ).height
                h = nodeBaseHeight + textHeight + 2
            } else {
                h = nodeBaseHeight + disasmFont.ascender - disasmFont.descender + disasmFont.leading
            }

            nodeHeightCache[node.address] = h
            return h
        }

        func fetchDisasmForVisibleNodes() {
            for (addr, node) in graph.nodes {
                guard disasmRaw[addr] == nil else { continue }

                let size = blockBytes[addr]?.count ?? node.size
                if let provider = disasmProvider {
                    Task { @MainActor in
                        var result = await provider(addr, size)
                        while result.hasSuffix("\n") { result.removeLast() }
                        self.disasmRaw[addr] = result
                        self.disasmRendered[addr] = self.renderDisasm(result)
                        self.nodeHeightCache.removeValue(forKey: addr)
                        self.scheduleRelayout()
                    }
                }
            }
        }

        private func scheduleRelayout() {
            layoutDebounce?.cancel()
            layoutDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }

                let nodes = self.graph.nodes
                self.graph.assignPositions { addr in
                    self.nodeHeight(for: nodes[addr]!)
                }
                self.container?.metalView.needsDisplay = true
                self.container?.textOverlay.needsDisplay = true
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
                let color: SIMD4<Float> = isDarkMode
                    ? SIMD4(0.4, 0.6 + 0.4 * intensity, 1.0, 0.3 + 0.5 * intensity)
                    : SIMD4(0.2, 0.3 + 0.3 * intensity, 0.8, 0.4 + 0.4 * intensity)

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
                let isSelected = node.address == selectedAddress
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
                let bw: Float = 1 / Float(viewSize.width)
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
                    isSelected: isSelected
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

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            camera.offset.x += translation.x
            camera.offset.y -= translation.y
            gesture.setTranslation(.zero, in: gesture.view)
            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            camera.zoom *= 1 + gesture.magnification
            camera.zoom = max(0.1, min(10, camera.zoom))
            gesture.magnification = 0
            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view else { return }
            let raw = gesture.location(in: view)
            let viewSize = view.bounds.size
            let loc = CGPoint(x: raw.x, y: viewSize.height - raw.y)

            let worldX = (loc.x - viewSize.width / 2 - camera.offset.x) / camera.zoom
            let worldY = (loc.y - viewSize.height / 2 - camera.offset.y) / camera.zoom

            var bestAddr: UInt64?
            var bestDist: CGFloat = .greatestFiniteMagnitude

            for (_, node) in graph.nodes {
                let h = nodeHeight(for: node)
                let dx = CGFloat(node.position.x) - worldX
                let dy = CGFloat(node.position.y) - worldY
                let dist = dx * dx + dy * dy
                if dist < bestDist && abs(dx) < nodeWidth / 2 && abs(dy) < h / 2 {
                    bestDist = dist
                    bestAddr = node.address
                }
            }

            selectedBinding.wrappedValue = bestAddr
            container?.metalView.needsDisplay = true
            container?.textOverlay.needsDisplay = true
        }
    }
}
