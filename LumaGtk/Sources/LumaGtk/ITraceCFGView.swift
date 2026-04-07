import Cairo
import Foundation
import Gtk
import LumaCore

struct NodeRegisterInfo {
    let stateBeforeBlock: RegisterState
    let stateAfterBlock: RegisterState
    let writes: [RegisterWrite]
}

@MainActor
final class ITraceCFGView {
    let widget: ScrolledWindow

    var onSelect: ((CFGGraph.NodeKey) -> Void)?

    private let graph: CFGGraph
    private let nodeRegisterInfo: [CFGGraph.NodeKey: NodeRegisterInfo]
    private let drawingArea: DrawingArea
    private let fixed: Fixed
    private var nodeWidgets: [CFGGraph.NodeKey: Box] = [:]
    private var selectedKey: CFGGraph.NodeKey?

    private let blockWidth: Double = 180
    private let blockHeight: Double = 60
    private let padding: Double = 40

    init(graph: CFGGraph, nodeRegisterInfo: [CFGGraph.NodeKey: NodeRegisterInfo]) {
        self.graph = graph
        self.nodeRegisterInfo = nodeRegisterInfo

        let (minX, minY, maxX, maxY) = Self.bounds(of: graph, blockWidth: 180, blockHeight: 60)
        let contentWidth = Int((maxX - minX) + 2 * padding)
        let contentHeight = Int((maxY - minY) + 2 * padding)

        let overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        overlay.setSizeRequest(width: contentWidth, height: contentHeight)

        let area = DrawingArea()
        area.hexpand = true
        area.vexpand = true
        area.contentWidth = contentWidth
        area.contentHeight = contentHeight
        self.drawingArea = area

        let fixedContainer = Fixed()
        fixedContainer.hexpand = true
        fixedContainer.vexpand = true
        fixedContainer.setSizeRequest(width: contentWidth, height: contentHeight)
        self.fixed = fixedContainer

        overlay.set(child: WidgetRef(area.widget_ptr))
        overlay.addOverlay(widget: fixedContainer)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: WidgetRef(overlay.widget_ptr))
        self.widget = scroll

        let offsetX = padding - minX
        let offsetY = padding - minY

        for (key, node) in graph.nodes {
            let box = makeNodeBox(node: node)
            nodeWidgets[key] = box
            let x = node.position.x - blockWidth / 2 + offsetX
            let y = node.position.y - blockHeight / 2 + offsetY
            fixedContainer.put(widget: box, x: CDouble(x), y: CDouble(y))
        }

        let padding = self.padding
        let blockW = self.blockWidth
        let blockH = self.blockHeight
        area.setDrawFunc { [weak self] _, ctx, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draw(
                    ctx: ctx,
                    offsetX: padding - minX,
                    offsetY: padding - minY,
                    blockWidth: blockW,
                    blockHeight: blockH
                )
            }
        }
    }

    private static func bounds(
        of graph: CFGGraph,
        blockWidth: Double,
        blockHeight: Double
    ) -> (Double, Double, Double, Double) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for node in graph.nodes.values {
            minX = min(minX, node.position.x - blockWidth / 2)
            minY = min(minY, node.position.y - blockHeight / 2)
            maxX = max(maxX, node.position.x + blockWidth / 2)
            maxY = max(maxY, node.position.y + blockHeight / 2)
        }
        if !minX.isFinite {
            return (0, 0, blockWidth, blockHeight)
        }
        return (minX, minY, maxX, maxY)
    }

    private func makeNodeBox(node: CFGGraph.Node) -> Box {
        let box = Box(orientation: .vertical, spacing: 0)
        box.setSizeRequest(width: Int(blockWidth), height: Int(blockHeight))
        box.add(cssClass: "luma-cfg-node")
        box.halign = .start
        box.valign = .start

        let nameLabel = Label(str: node.name)
        nameLabel.halign = .start
        nameLabel.add(cssClass: "caption")
        nameLabel.add(cssClass: "monospace")
        nameLabel.ellipsize = .end
        nameLabel.setSizeRequest(width: Int(blockWidth) - 20, height: -1)
        box.append(child: nameLabel)

        let visitLabel = Label(str: "\(node.visitCount)\u{00D7}")
        visitLabel.halign = .start
        visitLabel.add(cssClass: "dim-label")
        visitLabel.add(cssClass: "caption")
        box.append(child: visitLabel)

        if let info = nodeRegisterInfo[node.key], !info.writes.isEmpty {
            let first = info.writes.prefix(2)
                .map { String(format: "%@=0x%llx", $0.registerName, $0.value) }
                .joined(separator: " ")
            let regLabel = Label(str: first)
            regLabel.halign = .start
            regLabel.add(cssClass: "dim-label")
            regLabel.add(cssClass: "caption")
            regLabel.add(cssClass: "monospace")
            regLabel.ellipsize = .end
            regLabel.setSizeRequest(width: Int(blockWidth) - 20, height: -1)
            box.append(child: regLabel)
        }

        let gesture = GestureClick()
        gesture.button = 1
        let key = node.key
        gesture.onPressed { [weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                self?.select(key: key)
            }
        }
        box.add(controller: gesture)

        return box
    }

    private func select(key: CFGGraph.NodeKey) {
        if let prev = selectedKey, let prevBox = nodeWidgets[prev] {
            prevBox.remove(cssClass: "selected")
        }
        selectedKey = key
        if let box = nodeWidgets[key] {
            box.add(cssClass: "selected")
        }
        drawingArea.queueDraw()
        onSelect?(key)
    }

    private func draw(
        ctx: Cairo.ContextRef,
        offsetX: Double,
        offsetY: Double,
        blockWidth: Double,
        blockHeight: Double
    ) {
        for edge in graph.edges {
            guard
                let from = graph.nodes[edge.from],
                let to = graph.nodes[edge.to]
            else { continue }

            let x1 = from.position.x + offsetX
            let y1 = from.position.y + blockHeight / 2 + offsetY
            let x2 = to.position.x + offsetX
            let y2 = to.position.y - blockHeight / 2 + offsetY

            let width = min(8.0, max(1.0, log2(Double(edge.count) + 1)))
            ctx.lineWidth = width

            let highlighted: Bool
            if let sel = selectedKey {
                highlighted = (edge.from == sel || edge.to == sel)
            } else {
                highlighted = false
            }

            if highlighted {
                ctx.setSource(red: 0.33, green: 0.55, blue: 0.93, alpha: 0.95)
            } else {
                ctx.setSource(red: 0.6, green: 0.6, blue: 0.62, alpha: 0.75)
            }

            if edge.isCrossSection {
                ctx.setDash([6.0, 4.0], offset: 0.0)
            } else {
                ctx.setDash([], offset: 0.0)
            }

            ctx.moveTo(x1, y1)
            ctx.lineTo(x2, y2)
            ctx.stroke()

            drawArrowHead(ctx: ctx, x1: x1, y1: y1, x2: x2, y2: y2, width: width)
        }
    }

    private func drawArrowHead(
        ctx: Cairo.ContextRef,
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double,
        width: Double
    ) {
        let dx = x2 - x1
        let dy = y2 - y1
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.001 else { return }
        let ux = dx / len
        let uy = dy / len
        let size = max(6.0, width * 2.5)
        let baseX = x2 - ux * size
        let baseY = y2 - uy * size
        let px = -uy
        let py = ux
        ctx.setDash([], offset: 0.0)
        ctx.moveTo(x2, y2)
        ctx.lineTo(baseX + px * size * 0.5, baseY + py * size * 0.5)
        ctx.lineTo(baseX - px * size * 0.5, baseY - py * size * 0.5)
        ctx.closePath()
        ctx.fill()
    }
}
