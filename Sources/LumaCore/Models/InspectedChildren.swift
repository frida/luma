import Foundation

public struct InspectedChildren: Sendable {
    public static let pageSize = 5

    public enum Kind: Sendable {
        case properties
        case items
        case entries
    }

    public let kind: Kind
    public let total: Int

    public init(_ kind: Kind, total: Int) {
        self.kind = kind
        self.total = total
    }

    public var initiallyShown: Int {
        min(total, Self.pageSize)
    }

    public func shown(afterMoreThan shown: Int) -> Int {
        min(shown + Self.pageSize, total)
    }

    public func showMoreTitle(shown: Int) -> String {
        let remaining = total - shown
        let next = min(Self.pageSize, remaining)
        if next == remaining {
            return "Show \(remaining) more \(named(remaining))…"
        }
        return "Show \(next) more (\(remaining) \(named(remaining)) left)…"
    }

    private func named(_ count: Int) -> String {
        switch (kind, count) {
        case (.properties, 1): "property"
        case (.properties, _): "properties"
        case (.items, 1): "item"
        case (.items, _): "items"
        case (.entries, 1): "entry"
        case (.entries, _): "entries"
        }
    }
}
