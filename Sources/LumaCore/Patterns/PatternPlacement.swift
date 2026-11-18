import Foundation

public struct PatternPlacement: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: String
    public var typeName: String
    public var offset: Int
    public var origin: UInt64?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case typeName = "type_name"
        case offset
        case origin
    }

    public init(id: UUID = UUID(), sourceID: String, typeName: String, offset: Int, origin: UInt64? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.typeName = typeName
        self.offset = offset
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        typeName = try container.decode(String.self, forKey: .typeName)
        offset = try container.decode(Int.self, forKey: .offset)
        origin = try container.decodeIfPresent(String.self, forKey: .origin).flatMap { UInt64($0.dropFirst(2), radix: 16) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(typeName, forKey: .typeName)
        try container.encode(offset, forKey: .offset)
        try container.encodeIfPresent(origin.map { String(format: "0x%llx", $0) }, forKey: .origin)
    }
}

extension [PatternPlacement] {
    public init(wireJSON placements: [[String: Any]]) {
        self = placements.compactMap { placement in
            (try? JSONSerialization.data(withJSONObject: placement)).flatMap { try? JSONDecoder().decode(PatternPlacement.self, from: $0) }
        }
    }

    public var wireJSON: [[String: Any]] {
        let data = try! JSONEncoder().encode(self)
        return try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    public func placed(at origin: UInt64?) -> [PatternPlacement] {
        filter { $0.origin == origin }
    }

    public func replacingThose(at origin: UInt64?, with replacements: [PatternPlacement]) -> [PatternPlacement] {
        let elsewhere = filter { $0.origin != origin }
        return elsewhere
            + replacements.map { placement in
                var placed = placement
                placed.origin = origin
                return placed
            }
    }
}
