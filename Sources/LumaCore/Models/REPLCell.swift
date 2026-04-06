import Foundation

public struct REPLCell: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var code: String
    public var result: Result
    public var timestamp: Date
    public var isSessionBoundary: Bool

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
