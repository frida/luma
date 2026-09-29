import Foundation
import GRDB

public struct REPLCell: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repl_cell"

    public var id: UUID
    public var sessionID: UUID
    public var author: Author?
    public var code: String
    public var language: REPLLanguage
    public var result: Result
    public var placements: [PatternPlacement]
    public var timestamp: Date
    public var isSessionBoundary: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case author
        case code
        case language
        case result
        case placements
        case timestamp
        case isSessionBoundary = "is_session_boundary"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        author: Author? = nil,
        code: String,
        language: REPLLanguage = .javascript,
        result: Result,
        placements: [PatternPlacement] = [],
        timestamp: Date = .now,
        isSessionBoundary: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.author = author
        self.code = code
        self.language = language
        self.result = result
        self.placements = placements
        self.timestamp = timestamp
        self.isSessionBoundary = isSessionBoundary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        author = try container.decodeIfPresent(Author.self, forKey: .author)
        code = try container.decode(String.self, forKey: .code)
        language = try container.decode(REPLLanguage.self, forKey: .language)
        result = try container.decode(Result.self, forKey: .result)
        placements = try container.decodeIfPresent([PatternPlacement].self, forKey: .placements) ?? []
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isSessionBoundary = try container.decode(Bool.self, forKey: .isSessionBoundary)
    }

    public enum Result: Codable, Equatable, Sendable {
        case text(String)
        case styled(StyledText)
        case js(JSInspectValue)
        case binary(Data, meta: BinaryMeta?)

        public struct BinaryMeta: Codable, Equatable, Sendable {
            public let typedArray: String?
            public let baseAddress: UInt64?

            public init(typedArray: String?, baseAddress: UInt64? = nil) {
                self.typedArray = typedArray
                self.baseAddress = baseAddress
            }
        }
    }

    private static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.dataEncodingStrategy = .base64
        return e
    }()

    private static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.dataDecodingStrategy = .base64
        return d
    }()

    public func toWireJSON() -> [String: Any]? {
        guard let data = try? Self.wireEncoder.encode(self),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> REPLCell? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let cell = try? wireDecoder.decode(REPLCell.self, from: data)
        else { return nil }
        return cell
    }
}
