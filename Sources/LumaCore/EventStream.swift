import Foundation

public struct RuntimeEvent: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let kind: Kind

    public enum Kind: Sendable {
        case processOutput(fd: Int, data: Data)
        case console(level: ConsoleLevel, message: String)
        case error(description: String)
        case instrumentEvent(instrumentID: UUID, payload: InstrumentEventPayload)
    }

    public init(timestamp: Date = .now, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

public final class InstrumentEventPayload: @unchecked Sendable {
    public let values: [String: Any]

    public init(_ values: [String: Any]) {
        self.values = values
    }
}

public enum ConsoleLevel: String, Sendable, Codable {
    case log, warn, error, debug, info
}

@MainActor
public final class EventStream: Sendable {
    public private(set) var events: [RuntimeEvent] = []
    public private(set) var version: Int = 0

    private let maxVisible = 1_000
    private let maxInMemory = 10_000
    private var allEvents: [RuntimeEvent] = []

    public init() {}

    public func push(_ event: RuntimeEvent) {
        allEvents.append(event)
        if allEvents.count > maxInMemory {
            allEvents.removeFirst(allEvents.count - maxInMemory)
        }
        let start = max(0, allEvents.count - maxVisible)
        events = Array(allEvents[start...])
        version += 1
    }

    public func clear() {
        allEvents.removeAll()
        events.removeAll()
        version += 1
    }
}
