import Foundation

public struct PatternLocation: Sendable {
    public let node: DecodedPattern
    public let range: Range<Int>
    public let ancestors: [UUID]
    public let tint: PatternTint
    public let isLeaf: Bool

    public static func locateFields(of root: DecodedPattern, under ancestor: UUID, base: UInt64, into located: inout [UUID: PatternLocation]) {
        for (index, field) in root.children.enumerated() where !field.hidden {
            locate(field, ancestors: [ancestor], tint: PatternTint(node: field, index: index), base: base, into: &located)
        }
    }

    private static func locate(
        _ node: DecodedPattern, ancestors: [UUID], tint: PatternTint, base: UInt64, into located: inout [UUID: PatternLocation]
    ) {
        let children = node.visibleChildren
        let ownTint = node.color.flatMap(PatternTint.init(hex:)) ?? tint
        if let size = node.size, size > 0, node.address >= base {
            let start = Int(node.address - base)
            let isLeaf = !children.contains { ($0.size ?? 0) > 0 }
            located[node.id] = PatternLocation(node: node, range: start..<start + size, ancestors: ancestors, tint: ownTint, isLeaf: isLeaf)
        }
        for child in children {
            locate(child, ancestors: ancestors + [node.id], tint: ownTint, base: base, into: &located)
        }
    }
}

public enum PatternTint: Hashable, Sendable {
    case palette(Int)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)

    public init(node: DecodedPattern, index: Int) {
        self = node.color.flatMap(PatternTint.init(hex:)) ?? .palette(index)
    }

    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self = .rgb(red: UInt8((value >> 16) & 0xff), green: UInt8((value >> 8) & 0xff), blue: UInt8(value & 0xff))
    }
}

extension DecodedPattern {
    public var visibleChildren: [DecodedPattern] {
        sealed ? [] : children.filter { !$0.hidden }
    }
}
