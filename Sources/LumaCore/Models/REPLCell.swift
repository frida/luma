import Foundation
import GRDB

public struct REPLCell: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repl_cell"

    public var id: UUID
    public var sessionID: UUID
    public var code: String
    public var result: Result
    public var timestamp: Date
    public var isSessionBoundary: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case code
        case result
        case timestamp
        case isSessionBoundary = "is_session_boundary"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        code: String,
        result: Result,
        timestamp: Date = .now,
        isSessionBoundary: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.code = code
        self.result = result
        self.timestamp = timestamp
        self.isSessionBoundary = isSessionBoundary
    }

    public enum Result: Codable, Equatable, Sendable {
        case text(String)
        case js(JSInspectValue)
        case binary(Data, meta: BinaryMeta?)

        public struct BinaryMeta: Codable, Equatable, Sendable {
            public let typedArray: String?

            public init(typedArray: String?) {
                self.typedArray = typedArray
            }
        }
    }
}
