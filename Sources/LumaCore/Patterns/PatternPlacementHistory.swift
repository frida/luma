import Foundation
import Observation

@Observable
@MainActor
public final class PatternPlacementHistory {
    public static let limit = 6

    public private(set) var recent: [Entry] = []

    public struct Entry: Hashable, Sendable {
        public let sourceID: String
        public let typeName: String
    }

    public func note(_ placement: PatternPlacement) {
        let entry = Entry(sourceID: placement.sourceID, typeName: placement.typeName)
        recent.removeAll { $0 == entry }
        recent.insert(entry, at: 0)
        recent = Array(recent.prefix(Self.limit))
    }
}
