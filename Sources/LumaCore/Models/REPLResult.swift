import Foundation

public struct REPLResult: Sendable {
    public let code: String
    public let value: Value
    public let timestamp: Date

    public enum Value: @unchecked Sendable {
        case js(JSInspectValue)
        case text(String)
    }

    public init(code: String, value: Value, timestamp: Date = .now) {
        self.code = code
        self.value = value
        self.timestamp = timestamp
    }
}
