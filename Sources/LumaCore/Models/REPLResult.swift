import Foundation

public struct REPLResult: Sendable {
    public let id: UUID
    public let code: String
    public let value: Value
    public let timestamp: Date

    public enum Value: @unchecked Sendable {
        case js(JSInspectValue)
        case text(String)
    }

    public init(id: UUID = UUID(), code: String, value: Value, timestamp: Date = .now) {
        self.id = id
        self.code = code
        self.value = value
        self.timestamp = timestamp
    }
}
