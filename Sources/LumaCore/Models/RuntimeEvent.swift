import Foundation

public struct RuntimeEvent: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var sessionID: UUID?
    public let source: Source
    public let payload: Payload
    public let data: [UInt8]?

    public enum Source: Sendable {
        case processOutput(fd: Int)
        case script
        case console
        case repl
        case instrument(id: UUID, name: String)
    }

    public enum Payload: @unchecked Sendable {
        case consoleMessage(ConsoleMessage)
        case jsError(JSError)
        case jsValue(JSInspectValue)
        case raw(message: Any, data: [UInt8]?)
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        sessionID: UUID? = nil,
        source: Source,
        payload: Payload,
        data: [UInt8]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.source = source
        self.payload = payload
        self.data = data
    }
}
