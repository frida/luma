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
}
