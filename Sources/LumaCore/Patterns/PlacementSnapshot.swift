import Foundation

public struct PlacementSnapshot: Codable, Sendable {
    public static let nodeLimit = 2000

    public let placementID: UUID
    public let typeName: String
    public let offset: Int
    public let origin: String?
    public let root: Node?
    public let problem: String?

    enum CodingKeys: String, CodingKey {
        case placementID = "placement_id"
        case typeName = "type_name"
        case offset
        case origin
        case root
        case problem
    }

    public init(of placement: PatternPlacement, decoded: DecodedPattern, base: UInt64) {
        var budget = Self.nodeLimit
        self.init(of: placement, root: Node(decoded, base: base, budget: &budget), problem: nil)
    }

    public init(of placement: PatternPlacement, problem: String) {
        self.init(of: placement, root: nil, problem: problem)
    }

    private init(of placement: PatternPlacement, root: Node?, problem: String?) {
        placementID = placement.id
        typeName = placement.typeName
        offset = placement.offset
        origin = placement.origin.map { String(format: "0x%llx", $0) }
        self.root = root
        self.problem = problem
    }

    public struct Node: Codable, Sendable {
        public let name: String
        public let typeName: String
        public let offset: Int
        public let size: Int
        public let value: String
        public let children: [Node]
        public let truncated: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case typeName = "type"
            case offset
            case size
            case value
            case children
            case truncated
        }

        init(_ node: DecodedPattern, base: UInt64, budget: inout Int) {
            name = node.title
            typeName = node.typeName
            offset = Int(truncatingIfNeeded: node.address &- base)
            size = node.size ?? 0
            value = node.summary
            var kept: [Node] = []
            for child in node.visibleChildren {
                guard budget > 0 else { break }
                budget -= 1
                kept.append(Node(child, base: base, budget: &budget))
            }
            children = kept
            truncated = node.truncated || kept.count < node.visibleChildren.count
        }
    }
}
