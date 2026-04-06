import Foundation

public struct InstrumentInstance: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var kind: InstrumentKind
    public var sourceIdentifier: String
    public var isEnabled: Bool
    public var configJSON: Data

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        kind: InstrumentKind,
        sourceIdentifier: String,
        isEnabled: Bool = true,
        configJSON: Data
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.isEnabled = isEnabled
        self.configJSON = configJSON
    }
}
