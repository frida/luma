import Foundation

public struct PatternPlacement: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: String
    public var typeName: String
    public var offset: Int

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case typeName = "type_name"
        case offset
    }

    public init(id: UUID = UUID(), sourceID: String, typeName: String, offset: Int) {
        self.id = id
        self.sourceID = sourceID
        self.typeName = typeName
        self.offset = offset
    }

    public func toWireJSON() -> [String: Any] {
        [
            "id": id.uuidString,
            "source_id": sourceID,
            "type_name": typeName,
            "offset": offset,
        ]
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> PatternPlacement? {
        guard let id = (obj["id"] as? String).flatMap(UUID.init(uuidString:)),
            let sourceID = obj["source_id"] as? String,
            let typeName = obj["type_name"] as? String,
            let offset = obj["offset"] as? Int
        else { return nil }
        return PatternPlacement(id: id, sourceID: sourceID, typeName: typeName, offset: offset)
    }
}
