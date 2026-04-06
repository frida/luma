import Foundation

public struct CFGGraph {
    public typealias NodeKey = UInt64

    public struct Point2D: Sendable, Hashable {
        public var x: Double
        public var y: Double

        public static let zero = Point2D(x: 0, y: 0)

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public static func nodeKey(address: UInt64, section: Int) -> NodeKey {
        address | (UInt64(section) << 62)
    }

    public static func nodeAddress(_ key: NodeKey) -> UInt64 {
        key & 0x3FFF_FFFF_FFFF_FFFF
    }

    public struct Node {
        public let key: NodeKey
        public let address: UInt64
        public let name: String
        public let size: Int
        public let visitCount: Int
        public let section: Int
        public var position: Point2D = .zero
        public var layer: Int = 0

        public init(key: NodeKey, address: UInt64, name: String, size: Int, visitCount: Int, section: Int) {
            self.key = key
            self.address = address
            self.name = name
            self.size = size
            self.visitCount = visitCount
            self.section = section
        }
    }

    public struct Edge {
        public let from: NodeKey
        public let to: NodeKey
        public let count: Int
        public let isCrossSection: Bool

        public init(from: NodeKey, to: NodeKey, count: Int, isCrossSection: Bool) {
            self.from = from
            self.to = to
            self.count = count
            self.isCrossSection = isCrossSection
        }
    }

    public var nodes: [NodeKey: Node]
    public var edges: [Edge]
    public var entryKey: NodeKey
    public var sectionCount: Int = 1

    public init(nodes: [NodeKey: Node], edges: [Edge], entryKey: NodeKey) {
        self.nodes = nodes
        self.edges = edges
        self.entryKey = entryKey
    }

    public static func build<S: Collection>(from entries: S, section: Int = 0) -> CFGGraph where S.Element == TraceEntry {
        var nodeCounts: [NodeKey: Int] = [:]
        var nodeInfo: [NodeKey: (address: UInt64, name: String, size: Int)] = [:]

        for entry in entries {
            let key = nodeKey(address: entry.blockAddress, section: section)
            nodeCounts[key, default: 0] += 1
            if nodeInfo[key] == nil {
                nodeInfo[key] = (address: entry.blockAddress, name: entry.blockName, size: entry.blockSize)
            }
        }

        var nodes: [NodeKey: Node] = [:]
        for (key, count) in nodeCounts {
            let info = nodeInfo[key]!
            nodes[key] = Node(
                key: key,
                address: info.address,
                name: info.name,
                size: info.size,
                visitCount: count,
                section: section
            )
        }

        let entriesArray = Array(entries)
        var edgeCounts: [NodeKey: [NodeKey: Int]] = [:]
        for (a, b) in zip(entriesArray, entriesArray.dropFirst()) {
            let fromKey = nodeKey(address: a.blockAddress, section: section)
            let toKey = nodeKey(address: b.blockAddress, section: section)
            edgeCounts[fromKey, default: [:]][toKey, default: 0] += 1
        }

        var edges: [Edge] = []
        for (from, targets) in edgeCounts {
            for (to, count) in targets {
                edges.append(Edge(from: from, to: to, count: count, isCrossSection: false))
            }
        }

        let entryKey = entriesArray.first.map { nodeKey(address: $0.blockAddress, section: section) } ?? 0

        var graph = CFGGraph(nodes: nodes, edges: edges, entryKey: entryKey)
        graph.layout()
        return graph
    }

    public static func buildAllFunctions(
        sections: [(entries: ArraySlice<TraceEntry>, section: Int)],
        currentSection: Int
    ) -> CFGGraph {
        let currentEntries = sections.first { $0.section == currentSection }?.entries
        let entryKey = currentEntries?.first.map { nodeKey(address: $0.blockAddress, section: currentSection) } ?? 0
        var combined = CFGGraph(nodes: [:], edges: [], entryKey: entryKey)

        for (entries, section) in sections where !entries.isEmpty {
            let sub = build(from: entries, section: section)
            for (key, node) in sub.nodes {
                combined.nodes[key] = node
            }
            combined.edges.append(contentsOf: sub.edges)
        }

        combined.sectionCount = sections.count

        for i in 0..<(sections.count - 1) {
            let (prevEntries, prevSection) = sections[i]
            let (nextEntries, nextSection) = sections[i + 1]
            guard let lastPrev = prevEntries.last, let firstNext = nextEntries.first else { continue }

            combined.edges.append(Edge(
                from: nodeKey(address: lastPrev.blockAddress, section: prevSection),
                to: nodeKey(address: firstNext.blockAddress, section: nextSection),
                count: 1,
                isCrossSection: true
            ))
        }

        combined.assignPositions()

        return combined
    }

    // MARK: - Layout

    public mutating func layout() {
        assignLayers()
        assignPositions()
    }

    private mutating func assignLayers() {
        var adjacency: [NodeKey: [NodeKey]] = [:]
        for edge in edges where !edge.isCrossSection {
            adjacency[edge.from, default: []].append(edge.to)
        }

        struct EdgePair: Hashable { let from: NodeKey; let to: NodeKey }
        var backEdges = Set<EdgePair>()
        var visited = Set<NodeKey>()
        var onStack = Set<NodeKey>()

        func dfs(start: NodeKey) {
            var stack: [(node: NodeKey, neighborIdx: Int)] = [(start, 0)]
            visited.insert(start)
            onStack.insert(start)

            while !stack.isEmpty {
                let (node, idx) = stack.last!
                let neighbors = adjacency[node] ?? []

                if idx < neighbors.count {
                    stack[stack.count - 1].neighborIdx = idx + 1
                    let neighbor = neighbors[idx]
                    if onStack.contains(neighbor) {
                        backEdges.insert(EdgePair(from: node, to: neighbor))
                    } else if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        onStack.insert(neighbor)
                        stack.append((neighbor, 0))
                    }
                } else {
                    onStack.remove(node)
                    stack.removeLast()
                }
            }
        }

        dfs(start: entryKey)
        for key in nodes.keys where !visited.contains(key) {
            dfs(start: key)
        }

        for key in nodes.keys {
            nodes[key]?.layer = 0
        }

        var changed = true
        while changed {
            changed = false
            for (from, targets) in adjacency {
                guard let fromLayer = nodes[from]?.layer else { continue }
                for to in targets {
                    if backEdges.contains(EdgePair(from: from, to: to)) { continue }
                    guard let toLayer = nodes[to]?.layer else { continue }
                    if fromLayer + 1 > toLayer {
                        nodes[to]?.layer = fromLayer + 1
                        changed = true
                    }
                }
            }
        }
    }

    public mutating func assignPositions(nodeHeights: ((UInt64) -> Double)? = nil) {
        let nodeWidth: Double = 360
        let hSpacing: Double = 40
        let vSpacing: Double = 20
        let sectionGap: Double = 80

        var sectionNodes: [Int: [Int: [UInt64]]] = [:]
        for (addr, node) in nodes {
            sectionNodes[node.section, default: [:]][node.layer, default: []].append(addr)
        }

        var sectionWidths: [Int: Double] = [:]
        for (section, layers) in sectionNodes {
            var maxLayerWidth: Double = 0
            for (_, addrs) in layers {
                let w = Double(addrs.count) * (nodeWidth + hSpacing) - hSpacing
                maxLayerWidth = max(maxLayerWidth, w)
            }
            sectionWidths[section] = maxLayerWidth
        }

        let sortedSections = sectionNodes.keys.sorted()
        var sectionOffsets: [Int: Double] = [:]
        var xCursor: Double = 0
        for section in sortedSections {
            let w = sectionWidths[section] ?? 0
            sectionOffsets[section] = xCursor + w / 2
            xCursor += w + sectionGap
        }
        let totalWidth = xCursor - sectionGap
        let centerOffset = totalWidth / 2

        for section in sortedSections {
            let layers = sectionNodes[section]!
            let sectionCenterX = (sectionOffsets[section] ?? 0) - centerOffset

            var y: Double = 0
            for layer in layers.keys.sorted() {
                let addrs = layers[layer]!.sorted()
                let layerWidth = Double(addrs.count) * (nodeWidth + hSpacing) - hSpacing
                let startX = sectionCenterX - layerWidth / 2

                var maxHeight: Double = 0
                for addr in addrs {
                    maxHeight = max(maxHeight, nodeHeights?(addr) ?? 160)
                }

                for (i, addr) in addrs.enumerated() {
                    let x = startX + Double(i) * (nodeWidth + hSpacing) + nodeWidth / 2
                    nodes[addr]?.position = Point2D(x: x, y: y + maxHeight / 2)
                }

                y += maxHeight + vSpacing
            }
        }
    }
}
