import Foundation

public struct PatternNodeRemap {
    private let ids: [UUID: UUID]

    public init(from old: [UUID: DecodedPattern], to new: [UUID: DecodedPattern], placements: Set<UUID>) {
        var current: [NodeKey: UUID] = [:]
        for (placement, root) in new {
            root.forEachNode { current[NodeKey(placement: placement, node: $0.nodeID)] = $0.id }
        }
        var ids = Dictionary(uniqueKeysWithValues: placements.map { ($0, $0) })
        for (placement, root) in old {
            root.forEachNode { node in
                ids[node.id] = current[NodeKey(placement: placement, node: node.nodeID)]
            }
        }
        self.ids = ids
    }

    public func callAsFunction(_ id: UUID) -> UUID? {
        ids[id]
    }

    private struct NodeKey: Hashable {
        let placement: UUID
        let node: UInt
    }
}

extension DecodedPattern {
    fileprivate func forEachNode(_ body: (DecodedPattern) -> Void) {
        body(self)
        for child in children {
            child.forEachNode(body)
        }
    }
}
