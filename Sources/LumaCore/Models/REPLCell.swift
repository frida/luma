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

            private enum CodingKeys: String, CodingKey {
                case typedArray = "typed_array"
                case baseAddress = "base_address"
            }

            public init(from decoder: Decoder) throws {
                try decoder.requireKnownKeys(CodingKeys.self)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                typedArray = try c.decodeIfPresent(String.self, forKey: .typedArray)
                baseAddress = c.contains(.baseAddress) ? try HexAddress.decode(.baseAddress, from: c) : nil
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(typedArray, forKey: .typedArray)
                try c.encodeIfPresent(baseAddress.map(HexAddress.string), forKey: .baseAddress)
            }
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case text
            case styled
            case js
            case binary
        }

        private enum TextKeys: String, CodingKey {
            case text
        }

        private enum JSKeys: String, CodingKey {
            case value
        }

        private enum BinaryKeys: String, CodingKey {
            case data
            case meta
        }

        public init(from decoder: Decoder) throws {
            let (c, kind) = try decoder.soleKey(CodingKeys.self, of: "a REPL result")
            switch kind {
            case .text:
                self = .text(try c.strictlyNested(TextKeys.self, forKey: .text).decode(String.self, forKey: .text))
            case .styled:
                self = .styled(try c.decode(StyledText.self, forKey: .styled))
            case .js:
                self = .js(try c.strictlyNested(JSKeys.self, forKey: .js).decode(JSInspectValue.self, forKey: .value))
            case .binary:
                let binary = try c.strictlyNested(BinaryKeys.self, forKey: .binary)
                self = .binary(
                    try binary.decode(Data.self, forKey: .data), meta: try binary.decodeIfPresent(BinaryMeta.self, forKey: .meta))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                var nested = c.nestedContainer(keyedBy: TextKeys.self, forKey: .text)
                try nested.encode(text, forKey: .text)
            case .styled(let styled):
                try c.encode(styled, forKey: .styled)
            case .js(let value):
                var nested = c.nestedContainer(keyedBy: JSKeys.self, forKey: .js)
                try nested.encode(value, forKey: .value)
            case .binary(let data, let meta):
                var nested = c.nestedContainer(keyedBy: BinaryKeys.self, forKey: .binary)
                try nested.encode(data, forKey: .data)
                try nested.encodeIfPresent(meta, forKey: .meta)
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
