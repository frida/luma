import Foundation
import GRDB

public enum InstrumentState: String, Codable, Sendable {
    case enabled
    case disabled
}

public struct InstrumentInstance: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "instrument_instance"

    public var id: UUID
    public var sessionID: UUID
    public var kind: InstrumentKind
    public var sourceIdentifier: String
    public var state: InstrumentState
    public var configJSON: Data

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case kind
        case sourceIdentifier = "source_identifier"
        case state
        case configJSON = "config_json"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        kind: InstrumentKind,
        sourceIdentifier: String,
        state: InstrumentState = .enabled,
        configJSON: Data
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.state = state
        self.configJSON = configJSON
    }

    private static let wireEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64
        return e
    }()

    private static let wireDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()

    public func toWireJSON() -> [String: Any]? {
        guard let data = try? Self.wireEncoder.encode(self),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> InstrumentInstance? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let inst = try? wireDecoder.decode(InstrumentInstance.self, from: data)
        else { return nil }
        return inst
    }
}
