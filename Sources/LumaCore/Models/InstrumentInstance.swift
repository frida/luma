import Foundation
import GRDB

public struct InstrumentInstance: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "instrument_instance"

    public var id: UUID
    public var sessionID: UUID
    public var kind: InstrumentKind
    public var sourceIdentifier: String
    public var isEnabled: Bool
    public var configJSON: Data

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case kind
        case sourceIdentifier = "source_identifier"
        case isEnabled = "is_enabled"
        case configJSON = "config_json"
    }

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
