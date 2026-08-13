import Foundation

/// Arranges a `mondrian` graph's nodes for drawing, in whatever way it asked to
/// be laid out. The maths is plain and portable, so every frontend places the
/// nodes the same way and only the drawing differs.
public struct PharoGraphLayout {
    public let nodeCount: Int
    public let edges: [Edge]
    public let kind: Kind

    public struct Edge: Sendable, Equatable {
        public var from: Int
        public var to: Int
        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
    }

    public struct Solution: Sendable, Equatable {
        public let points: [Point]
        public let width: Double
        public let height: Double
        public subscript(_ i: Int) -> Point { points[i] }
    }

    public enum Kind: String, Sendable {
        case tree
        case horizontalTree
        case grid
        case circle
        case horizontalLine
        case verticalLine
        case force

        public init(_ name: String) {
            self = Kind(rawValue: name) ?? .grid
        }
    }

    public static let nodeWidth = 160.0
    public static let nodeHeight = 28.0
    private static let gapWidth = 40.0
    private static let gapHeight = 56.0

    public init(nodeCount: Int, edges: [Edge], kind: Kind) {
        self.nodeCount = nodeCount
        self.edges = edges
        self.kind = kind
    }

    public func solve() -> Solution {
        normalized(positions())
    }

    private func positions() -> [Point] {
        switch kind {
        case .grid: grid()
        case .circle: circle()
        case .horizontalLine: line(horizontal: true)
        case .verticalLine: line(horizontal: false)
        case .tree: tree(horizontal: false)
        case .horizontalTree: tree(horizontal: true)
        case .force: force()
        }
    }

    private func grid() -> [Point] {
        let columns = max(1, Int(Double(nodeCount).squareRoot().rounded(.up)))
        return (0..<nodeCount).map { i in
            Point(x: Double(i % columns) * strideWidth, y: Double(i / columns) * strideHeight)
        }
    }

    private func circle() -> [Point] {
        guard nodeCount > 1 else { return [Point(x: 0, y: 0)] }
        let radius = Double(nodeCount) * strideWidth / (2 * .pi)
        return (0..<nodeCount).map { i in
            let theta = 2 * .pi * Double(i) / Double(nodeCount)
            return Point(x: radius * cos(theta), y: radius * sin(theta))
        }
    }

    private func line(horizontal: Bool) -> [Point] {
        (0..<nodeCount).map { i in
            horizontal
                ? Point(x: Double(i) * strideWidth, y: 0)
                : Point(x: 0, y: Double(i) * strideHeight)
        }
    }

    private func tree(horizontal: Bool) -> [Point] {
        let depth = depths()
        var byLayer: [Int: [Int]] = [:]
        for node in 0..<nodeCount {
            byLayer[depth[node], default: []].append(node)
        }
        var points = [Point](repeating: Point(x: 0, y: 0), count: nodeCount)
        for (layer, nodes) in byLayer {
            for (slot, node) in nodes.enumerated() {
                let across = Double(slot) - Double(nodes.count - 1) / 2
                let along = Double(layer)
                points[node] = horizontal
                    ? Point(x: along * strideWidth, y: across * strideHeight)
                    : Point(x: across * strideWidth, y: along * strideHeight)
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

    private func force() -> [Point] {
        guard nodeCount > 1 else { return [Point(x: 0, y: 0)] }
        let area = Double(nodeCount) * 10000
        let k = area.squareRoot() / Double(nodeCount).squareRoot()
        var points = circle()
        for _ in 0..<300 {
            var dispX = [Double](repeating: 0, count: nodeCount)
            var dispY = [Double](repeating: 0, count: nodeCount)
            for a in 0..<nodeCount {
                for b in 0..<nodeCount where a != b {
                    let dx = points[a].x - points[b].x
                    let dy = points[a].y - points[b].y
                    let dist = max((dx * dx + dy * dy).squareRoot(), 0.01)
                    let repel = k * k / dist
                    dispX[a] += dx / dist * repel
                    dispY[a] += dy / dist * repel
                }
            }
            for edge in edges where edge.from != edge.to {
                let dx = points[edge.from].x - points[edge.to].x
                let dy = points[edge.from].y - points[edge.to].y
                let dist = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let attract = dist * dist / k
                let fx = dx / dist * attract
                let fy = dy / dist * attract
                dispX[edge.from] -= fx
                dispY[edge.from] -= fy
                dispX[edge.to] += fx
                dispY[edge.to] += fy
            }
            for i in 0..<nodeCount {
                let length = max((dispX[i] * dispX[i] + dispY[i] * dispY[i]).squareRoot(), 0.01)
                let capped = min(length, k)
                points[i].x += dispX[i] / length * capped
                points[i].y += dispY[i] / length * capped
            }
        }
        return points
    }

    private var strideWidth: Double { Self.nodeWidth + Self.gapWidth }
    private var strideHeight: Double { Self.nodeHeight + Self.gapHeight }

    private func normalized(_ raw: [Point]) -> Solution {
        let minX = raw.map(\.x).min() ?? 0
        let minY = raw.map(\.y).min() ?? 0
        let maxX = raw.map(\.x).max() ?? 0
        let maxY = raw.map(\.y).max() ?? 0
        let points = raw.map { Point(x: $0.x - minX + Self.nodeWidth / 2, y: $0.y - minY + Self.nodeHeight / 2) }
        return Solution(
            points: points,
            width: maxX - minX + Self.nodeWidth,
            height: maxY - minY + Self.nodeHeight)
    }
}
