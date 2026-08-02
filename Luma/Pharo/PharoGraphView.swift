#if os(macOS)
import LumaCore
import SwiftUI
import SwiftyPharo

#if canImport(AppKit)
import AppKit
#endif

struct PharoGraphView: View {
    let graph: PharoGraph
    var onDrill: ((Int) async -> PharoObject?)?
    var onSelect: (PharoObject) -> Void = { _ in }

    @State private var drilling = false
    @State private var placed: PharoGraphLayout.Solution?
    @State private var selected: Int?
    @State private var hovered: Int?
    @State private var scale: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var viewport: CGSize = .zero
    @State private var didFit = false
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
            didFit = false
            placed = PharoGraphLayout(nodeCount: graph.nodes.count, edges: graph.edges, kind: .init(graph.layout)).solve()
            attemptInitialFit()
            isFocused = true
        }
    }

    private func attemptInitialFit() {
        guard !didFit, placed != nil, viewport != .zero else { return }
        didFit = true
        fitToViewport()
    }

    private func graphBody(_ placed: PharoGraphLayout.Solution) -> some View {
        GeometryReader { geo in
            canvas(placed)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(panGesture)
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom(to: zoomBase * $0.magnification) }
                        .onEnded { _ in zoomBase = scale })
                .onChange(of: selected) { _, now in
                    if let now { reveal(now) }
                }
                .overlay(alignment: .bottomTrailing) { zoomControls }
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(.upArrow) { move(0, -1); return .handled }
                .onKeyPress(.downArrow) { move(0, 1); return .handled }
                .onKeyPress(.leftArrow) { move(-1, 0); return .handled }
                .onKeyPress(.rightArrow) { move(1, 0); return .handled }
                .onKeyPress(.return) { drillSelected(); return .handled }
                .onKeyPress(.escape) { selected = nil; return .handled }
                .onAppear { viewport = geo.size; attemptInitialFit() }
                .onChange(of: geo.size) { viewport = $1; attemptInitialFit() }
        }
        .frame(minHeight: 240)
    }

    private func canvas(_ placed: PharoGraphLayout.Solution) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in graph.edges {
                    let incident = edge.from == selected || edge.to == selected
                    drawEdge(from: placed[edge.from], to: placed[edge.to], incident: incident, in: context)
                }
            }
            .frame(width: placed.size.width, height: placed.size.height)
            .allowsHitTesting(false)

            ForEach(graph.nodes.indices, id: \.self) { index in
                node(graph.nodes[index].label, at: index)
                    .position(placed[index])
                    .allowsHitTesting(isOnScreen(placed[index]))
            }
        }
        .frame(width: placed.size.width, height: placed.size.height, alignment: .topLeading)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged {
                offset = CGSize(width: panBase.width + $0.translation.width, height: panBase.height + $0.translation.height)
            }
            .onEnded { _ in panBase = offset }
    }

    private func isOnScreen(_ point: CGPoint) -> Bool {
        guard viewport != .zero else { return true }
        let onScreen = CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
        let margin = PharoGraphLayout.nodeSize.width * scale
        return onScreen.x > -margin && onScreen.x < viewport.width + margin
            && onScreen.y > -margin && onScreen.y < viewport.height + margin
    }

    private func reveal(_ index: Int) {
        guard let placed, viewport != .zero else { return }
        let point = placed[index]
        let onScreen = CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
        let inset = PharoGraphLayout.nodeSize.width * scale
        guard onScreen.x < inset || onScreen.y < inset
            || onScreen.x > viewport.width - inset || onScreen.y > viewport.height - inset
        else { return }
        offset = CGSize(width: viewport.width / 2 - point.x * scale, height: viewport.height / 2 - point.y * scale)
        panBase = offset
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass") { zoom(to: scale / 1.3) }
            zoomButton("arrow.up.left.and.down.right.magnifyingglass") { fitToViewport() }
            zoomButton("plus.magnifyingglass") { zoom(to: scale * 1.3) }
        }
        .padding(8)
    }

    private func fitToViewport() {
        guard let placed, viewport.width > 0, viewport.height > 0 else { return }
        let margin = PharoGraphLayout.margin * 2
        let content = CGSize(width: placed.size.width + margin, height: placed.size.height + margin)
        zoom(to: min(1, min(viewport.width / content.width, viewport.height / content.height)))
        offset = CGSize(
            width: (viewport.width - placed.size.width * scale) / 2,
            height: (viewport.height - placed.size.height * scale) / 2)
        panBase = offset
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

    private func drawEdge(from: CGPoint, to: CGPoint, incident: Bool, in context: GraphicsContext) {
        let clipped = trim(from: from, to: to)
        let style: GraphicsContext.Shading = incident ? .color(.fridaBrand) : .color(.secondary.opacity(0.55))
        var line = Path()
        line.move(to: clipped.start)
        line.addLine(to: clipped.end)
        context.stroke(line, with: style, lineWidth: incident ? 2 : 1)
        context.fill(arrowhead(at: clipped.end, from: clipped.start), with: style)
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
        let border: AnyShapeStyle = isSelected
            ? AnyShapeStyle(Color.fridaBrand)
            : (hovered == index ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
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
                    .strokeBorder(border, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .pointerStyle(.link)
            .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
            .onTapGesture { activate(index) }
            .contextMenu {
                Button { copyToPasteboard(label) } label: { Label("Copy Label", systemImage: "doc.on.doc") }
            }
            .help(label)
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
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
        guard let onDrill, !drilling else { return }
        drilling = true
        Task {
            defer { drilling = false }
            if let drilled = await onDrill(index) {
                onSelect(drilled)
            }
        }
    }
}

/// The `CGPoint` face the view draws against, over the portable layout the two
/// frontends share.
struct PharoGraphLayout {
    let nodeCount: Int
    let edges: [PharoGraphEdge]
    let kind: LumaCore.PharoGraphLayout.Kind

    struct Solution {
        let points: [CGPoint]
        let size: CGSize
        var indices: Range<Int> { points.indices }
        subscript(_ i: Int) -> CGPoint { points[i] }
    }

    static let nodeSize = CGSize(
        width: LumaCore.PharoGraphLayout.nodeWidth,
        height: LumaCore.PharoGraphLayout.nodeHeight)
    static let margin = 24.0

    func solve() -> Solution {
        let solved = LumaCore.PharoGraphLayout(
            nodeCount: nodeCount,
            edges: edges.map { .init(from: $0.from, to: $0.to) },
            kind: kind
        ).solve()
        return Solution(
            points: solved.points.map { CGPoint(x: $0.x, y: $0.y) },
            size: CGSize(width: solved.width, height: solved.height))
    }
}
#endif
