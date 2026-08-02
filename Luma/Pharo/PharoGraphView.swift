import SwiftUI
import SwiftyPharo

struct PharoGraphView: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let view: String
    let graph: PharoGraph
    let onSelect: (PharoObject) -> Void

    @State private var drilling = false
    @State private var placed: PharoGraphLayout.Solution?
    @State private var selected: Int?
    @State private var scale: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let placed {
                graphBody(placed)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: graph.layout) {
            placed = PharoGraphLayout(nodeCount: graph.nodes.count, edges: graph.edges, kind: .init(graph.layout)).solve()
        }
    }

    private func graphBody(_ placed: PharoGraphLayout.Solution) -> some View {
        ScrollViewReader { scroller in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in graph.edges {
                            drawEdge(from: placed[edge.from], to: placed[edge.to], in: context)
                        }
                    }
                    .frame(width: placed.size.width, height: placed.size.height)

                    ForEach(graph.nodes.indices, id: \.self) { index in
                        node(graph.nodes[index].label, at: index)
                            .position(placed[index])
                            .id(index)
                    }
                }
                .frame(width: placed.size.width, height: placed.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: placed.size.width * scale, height: placed.size.height * scale, alignment: .topLeading)
                .padding(PharoGraphLayout.margin)
            }
            .onChange(of: selected) { _, now in
                if let now { withAnimation { scroller.scrollTo(now) } }
            }
        }
        .gesture(
            MagnifyGesture()
                .onChanged { zoom(to: zoomBase * $0.magnification) }
                .onEnded { _ in zoomBase = scale })
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { move(0, -1); return .handled }
        .onKeyPress(.downArrow) { move(0, 1); return .handled }
        .onKeyPress(.leftArrow) { move(-1, 0); return .handled }
        .onKeyPress(.rightArrow) { move(1, 0); return .handled }
        .onKeyPress(.return) { drillSelected(); return .handled }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass") { zoom(to: scale / 1.3) }
            zoomButton("1.magnifyingglass") { zoom(to: 1) }
            zoomButton("plus.magnifyingglass") { zoom(to: scale * 1.3) }
        }
        .padding(8)
    }

    private func zoomButton(_ symbol: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func zoom(to value: CGFloat) {
        scale = min(max(value, 0.3), 3)
        zoomBase = scale
    }

    private func drawEdge(from: CGPoint, to: CGPoint, in context: GraphicsContext) {
        let clipped = trim(from: from, to: to)
        var line = Path()
        line.move(to: clipped.start)
        line.addLine(to: clipped.end)
        context.stroke(line, with: .color(.secondary.opacity(0.55)), lineWidth: 1)
        context.fill(arrowhead(at: clipped.end, from: clipped.start), with: .color(.secondary.opacity(0.55)))
    }

    private func trim(from: CGPoint, to: CGPoint) -> (start: CGPoint, end: CGPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let inset = PharoGraphLayout.nodeSize.height / 2 + 2
        let ux = dx / length
        let uy = dy / length
        return (
            CGPoint(x: from.x + ux * inset, y: from.y + uy * inset),
            CGPoint(x: to.x - ux * inset, y: to.y - uy * inset))
    }

    private func arrowhead(at tip: CGPoint, from origin: CGPoint) -> Path {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        let size = 7.0
        let spread = 0.4
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - size * cos(angle - spread),
            y: tip.y - size * sin(angle - spread)))
        path.addLine(to: CGPoint(
            x: tip.x - size * cos(angle + spread),
            y: tip.y - size * sin(angle + spread)))
        path.closeSubpath()
        return path
    }

    private func node(_ label: String, at index: Int) -> some View {
        let isSelected = selected == index
        return Text(label)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: PharoGraphLayout.nodeSize.width)
            .background(.pharoPane, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { activate(index) }
            .help(label)
    }

    private func activate(_ index: Int) {
        if selected == index {
            drill(into: index)
        } else {
            select(index)
        }
    }

    private func select(_ index: Int) {
        selected = index
        isFocused = true
    }

    private func move(_ dx: Double, _ dy: Double) {
        guard let placed else { return }
        isFocused = true
        guard let from = selected else {
            selected = placed.points.isEmpty ? nil : 0
            return
        }
        if let next = neighbor(of: from, dx: dx, dy: dy, in: placed) {
            selected = next
        }
    }

    private func neighbor(of index: Int, dx: Double, dy: Double, in placed: PharoGraphLayout.Solution) -> Int? {
        let from = placed[index]
        var best: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for other in placed.indices where other != index {
            let vx = placed[other].x - from.x
            let vy = placed[other].y - from.y
            let along = vx * dx + vy * dy
            guard along > 0 else { continue }
            let across = abs(vx * dy - vy * dx)
            let score = along + across * 2
            if score < bestScore {
                bestScore = score
                best = other
            }
        }
        return best
    }

    private func drillSelected() {
        if let selected { drill(into: selected) }
    }

    private func drill(into index: Int) {
        guard !drilling else { return }
        drilling = true
        Task {
            defer { drilling = false }
            if let drilled = try? await runtime.drillInto(object, view: view, index: index + 1) {
                onSelect(drilled)
            }
        }
    }
}

struct PharoGraphLayout {
    let nodeCount: Int
    let edges: [PharoGraphEdge]
    let kind: Kind

    enum Kind: String {
        case tree
        case horizontalTree
        case grid
        case circle
        case horizontalLine
        case verticalLine
        case force

        init(_ name: String) {
            self = Kind(rawValue: name) ?? .grid
        }
    }

    struct Solution {
        let points: [CGPoint]
        let size: CGSize
        var indices: Range<Int> { points.indices }
        subscript(_ i: Int) -> CGPoint { points[i] }
    }

    static let nodeSize = CGSize(width: 160, height: 28)
    static let margin = 24.0
    static let gap = CGSize(width: 40, height: 56)

    func solve() -> Solution {
        let raw = positions()
        return normalized(raw)
    }

    private func positions() -> [CGPoint] {
        switch kind {
        case .grid: return grid()
        case .circle: return circle()
        case .horizontalLine: return line(horizontal: true)
        case .verticalLine: return line(horizontal: false)
        case .tree: return tree(horizontal: false)
        case .horizontalTree: return tree(horizontal: true)
        case .force: return force()
        }
    }

    private func grid() -> [CGPoint] {
        let columns = max(1, Int(Double(nodeCount).squareRoot().rounded(.up)))
        let step = stride()
        return (0..<nodeCount).map { i in
            CGPoint(x: Double(i % columns) * step.width, y: Double(i / columns) * step.height)
        }
    }

    private func circle() -> [CGPoint] {
        guard nodeCount > 1 else { return [.zero] }
        let radius = Double(nodeCount) * stride().width / (2 * .pi)
        return (0..<nodeCount).map { i in
            let theta = 2 * .pi * Double(i) / Double(nodeCount)
            return CGPoint(x: radius * cos(theta), y: radius * sin(theta))
        }
    }

    private func line(horizontal: Bool) -> [CGPoint] {
        let step = stride()
        return (0..<nodeCount).map { i in
            horizontal
                ? CGPoint(x: Double(i) * step.width, y: 0)
                : CGPoint(x: 0, y: Double(i) * step.height)
        }
    }

    private func tree(horizontal: Bool) -> [CGPoint] {
        let depth = depths()
        var byLayer: [Int: [Int]] = [:]
        for node in 0..<nodeCount {
            byLayer[depth[node], default: []].append(node)
        }
        let step = stride()
        var points = [CGPoint](repeating: .zero, count: nodeCount)
        for (layer, nodes) in byLayer {
            for (slot, node) in nodes.enumerated() {
                let across = Double(slot) - Double(nodes.count - 1) / 2
                let along = Double(layer)
                points[node] = horizontal
                    ? CGPoint(x: along * step.width, y: across * step.height)
                    : CGPoint(x: across * step.width, y: along * step.height)
            }
        }
        return points
    }

    private func depths() -> [Int] {
        var incoming = [Int](repeating: 0, count: nodeCount)
        for edge in edges where edge.from != edge.to {
            incoming[edge.to] += 1
        }
        var depth = [Int](repeating: 0, count: nodeCount)
        var visited = [Bool](repeating: false, count: nodeCount)
        var frontier = (0..<nodeCount).filter { incoming[$0] == 0 }
        if frontier.isEmpty { frontier = Array(0..<min(1, nodeCount)) }
        var level = 0
        while !frontier.isEmpty {
            var next: [Int] = []
            for node in frontier where !visited[node] {
                visited[node] = true
                depth[node] = level
                for edge in edges where edge.from == node && !visited[edge.to] {
                    next.append(edge.to)
                }
            }
            frontier = next
            level += 1
        }
        return depth
    }

    private func force() -> [CGPoint] {
        guard nodeCount > 1 else { return [.zero] }
        let area = Double(nodeCount) * 10000
        let k = area.squareRoot() / Double(nodeCount).squareRoot()
        var points = circle()
        for _ in 0..<300 {
            var disp = [CGPoint](repeating: .zero, count: nodeCount)
            for a in 0..<nodeCount {
                for b in 0..<nodeCount where a != b {
                    let dx = points[a].x - points[b].x
                    let dy = points[a].y - points[b].y
                    let dist = max(hypot(dx, dy), 0.01)
                    let repel = k * k / dist
                    disp[a].x += dx / dist * repel
                    disp[a].y += dy / dist * repel
                }
            }
            for edge in edges where edge.from != edge.to {
                let dx = points[edge.from].x - points[edge.to].x
                let dy = points[edge.from].y - points[edge.to].y
                let dist = max(hypot(dx, dy), 0.01)
                let attract = dist * dist / k
                let fx = dx / dist * attract
                let fy = dy / dist * attract
                disp[edge.from].x -= fx
                disp[edge.from].y -= fy
                disp[edge.to].x += fx
                disp[edge.to].y += fy
            }
            let limit = k
            for i in 0..<nodeCount {
                let length = max(hypot(disp[i].x, disp[i].y), 0.01)
                let capped = min(length, limit)
                points[i].x += disp[i].x / length * capped
                points[i].y += disp[i].y / length * capped
            }
        }
        return points
    }

    private func stride() -> CGSize {
        CGSize(
            width: Self.nodeSize.width + Self.gap.width,
            height: Self.nodeSize.height + Self.gap.height)
    }

    private func normalized(_ raw: [CGPoint]) -> Solution {
        let minX = raw.map(\.x).min() ?? 0
        let minY = raw.map(\.y).min() ?? 0
        let maxX = raw.map(\.x).max() ?? 0
        let maxY = raw.map(\.y).max() ?? 0
        let half = CGSize(width: Self.nodeSize.width / 2, height: Self.nodeSize.height / 2)
        let points = raw.map { CGPoint(x: $0.x - minX + half.width, y: $0.y - minY + half.height) }
        let size = CGSize(
            width: maxX - minX + Self.nodeSize.width,
            height: maxY - minY + Self.nodeSize.height)
        return Solution(points: points, size: size)
    }
}
