import Foundation

@MainActor
public final class InstrumentRuntime: Identifiable, Sendable {
    public let id: UUID
    public let kind: InstrumentKind
    public let sourceIdentifier: String

    public private(set) var isAttached = false
    public var isEnabled: Bool
    public var configJSON: Data

    public init(
        id: UUID = UUID(),
        kind: InstrumentKind,
        sourceIdentifier: String,
        isEnabled: Bool = true,
        configJSON: Data = Data("{}".utf8)
    ) {
        self.id = id
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.isEnabled = isEnabled
        self.configJSON = configJSON
    }

    public func markAttached() {
        isAttached = true
    }

    public func markDetached() {
        isAttached = false
    }
}

public enum InstrumentKind: String, Sendable, Codable, Hashable {
    case tracer
    case hookPack
    case codeShare
}
