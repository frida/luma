import CoreGraphics
import Foundation

struct CFGGraph {
    struct Node {
        let address: UInt64
        let name: String
        let size: Int
        let visitCount: Int
        var position: CGPoint = .zero
        var layer: Int = 0
    }

    struct Edge {
        let from: UInt64
        let to: UInt64
        let count: Int
    }

    var nodes: [UInt64: Node]
    var edges: [Edge]
    var entryAddress: UInt64

    static func build(from trace: DecodedITrace) -> CFGGraph {
        var nodeCounts: [UInt64: Int] = [:]
        var nodeInfo: [UInt64: (name: String, size: Int)] = [:]

        for entry in trace.entries {
            nodeCounts[entry.blockAddress, default: 0] += 1
            if nodeInfo[entry.blockAddress] == nil {
                nodeInfo[entry.blockAddress] = (name: entry.blockName, size: entry.blockSize)
            }
        }

        var nodes: [UInt64: Node] = [:]
        for (addr, count) in nodeCounts {
            let info = nodeInfo[addr]!
            nodes[addr] = Node(
                address: addr,
                name: info.name,
                size: info.size,
                visitCount: count
            )
        }

        // Build edges from consecutive entries.
        var edgeCounts: [UInt64: [UInt64: Int]] = [:]
        for (a, b) in zip(trace.entries, trace.entries.dropFirst()) {
            edgeCounts[a.blockAddress, default: [:]][b.blockAddress, default: 0] += 1
        }

        var edges: [Edge] = []
        for (from, targets) in edgeCounts {
            for (to, count) in targets {
                edges.append(Edge(from: from, to: to, count: count))
            }
        }

        let entryAddress = trace.entries.first?.blockAddress ?? 0

        var graph = CFGGraph(nodes: nodes, edges: edges, entryAddress: entryAddress)
        graph.layout()
        return graph
    }

    // MARK: - Layout

    mutating func layout() {
        assignLayers()
        assignPositions()
    }

    /// BFS from entry to assign layers (Y position).
    private mutating func assignLayers() {
        var adjacency: [UInt64: [UInt64]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }

        var visited = Set<UInt64>()
        var queue: [(UInt64, Int)] = [(entryAddress, 0)]
        visited.insert(entryAddress)

        while !queue.isEmpty {
            let (addr, layer) = queue.removeFirst()
            nodes[addr]?.layer = layer

            for neighbor in adjacency[addr] ?? [] {
                if !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append((neighbor, layer + 1))
                }
            }
        }

        // Assign unvisited nodes to a default layer.
        let maxLayer = nodes.values.map(\.layer).max() ?? 0
        for addr in nodes.keys where !visited.contains(addr) {
            nodes[addr]?.layer = maxLayer + 1
        }
    }

    /// Position nodes in a grid: Y = layer, X = order within layer.
    mutating func assignPositions(nodeHeights: ((UInt64) -> CGFloat)? = nil) {
        var layers: [Int: [UInt64]] = [:]
        for (addr, node) in nodes {
            layers[node.layer, default: []].append(addr)
        }

        let nodeWidth: CGFloat = 360
        let hSpacing: CGFloat = 60
        let vSpacing: CGFloat = 40

        var y: CGFloat = 0
        for layer in layers.keys.sorted() {
            let addrs = layers[layer]!.sorted()
            let layerWidth = CGFloat(addrs.count) * (nodeWidth + hSpacing) - hSpacing
            let startX = -layerWidth / 2

            var maxHeight: CGFloat = 0
            for addr in addrs {
                let h = nodeHeights?(addr) ?? 160
                maxHeight = max(maxHeight, h)
            }

            for (i, addr) in addrs.enumerated() {
                let x = startX + CGFloat(i) * (nodeWidth + hSpacing) + nodeWidth / 2
                nodes[addr]?.position = CGPoint(x: x, y: y + maxHeight / 2)
            }

            y += maxHeight + vSpacing
        }
    }
}
