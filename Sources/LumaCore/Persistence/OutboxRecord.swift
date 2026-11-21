import Foundation
import GRDB

public protocol OutboxOp: Sendable {
    static var outboxFamily: String { get }
    var opID: UUID { get }
    var kind: String { get }
    var outboxSubject: UUID { get }
    var outboxBinary: Data? { get }
    func toJSON() -> [String: Any]
    static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> Self?
}

extension OutboxOp {
    public var outboxBinary: Data? { nil }
}

public enum QueuedOp: Sendable {
    case notebook(NotebookOp)
    case session(SessionOp)
    case customInstrument(CustomInstrumentOp)
    case pattern(PatternSourceOp)
    case mission(MissionOp)
    case addressNote(AddressNoteOp)
}

struct OutboxRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox"

    var opID: String
    var family: String
    var kind: String
    var subjectID: String
    var payloadJSON: String
    var binaryData: Data?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case family
        case kind
        case subjectID = "subject_id"
        case payloadJSON = "payload_json"
        case binaryData = "binary_data"
        case createdAt = "created_at"
    }

    init<Op: OutboxOp>(_ op: Op) throws {
        let payload = try JSONSerialization.data(withJSONObject: op.toJSON(), options: [.sortedKeys])
        opID = op.opID.uuidString
        family = Op.outboxFamily
        kind = op.kind
        subjectID = op.outboxSubject.uuidString
        payloadJSON = String(decoding: payload, as: UTF8.self)
        binaryData = op.outboxBinary
        createdAt = Date()
    }

    func toQueuedOp() -> QueuedOp? {
        switch family {
        case NotebookOp.outboxFamily: toOp(NotebookOp.self).map(QueuedOp.notebook)
        case SessionOp.outboxFamily: toOp(SessionOp.self).map(QueuedOp.session)
        case CustomInstrumentOp.outboxFamily: toOp(CustomInstrumentOp.self).map(QueuedOp.customInstrument)
        case PatternSourceOp.outboxFamily: toOp(PatternSourceOp.self).map(QueuedOp.pattern)
        case MissionOp.outboxFamily: toOp(MissionOp.self).map(QueuedOp.mission)
        case AddressNoteOp.outboxFamily: toOp(AddressNoteOp.self).map(QueuedOp.addressNote)
        default: nil
        }
    }

    func toOp<Op: OutboxOp>(_ type: Op.Type) -> Op? {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any],
            let subject = UUID(uuidString: subjectID)
        else { return nil }
        return Op.fromOutbox(payload, subject: subject, binary: binaryData)
    }
}

extension NotebookOp: OutboxOp {
    public static let outboxFamily = "notebook"

    public var outboxSubject: UUID { entryID }

    public var outboxBinary: Data? {
        if case .add(let add) = self {
            return add.entry.binaryData
        }
        return nil
    }

    public static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> NotebookOp? {
        fromJSON(payload, binaryData: binary.map { [UInt8]($0) })
    }
}

extension SessionOp: OutboxOp {
    public static let outboxFamily = "session"

    public var outboxSubject: UUID { sessionID }

    public static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> SessionOp? {
        fromJSON(payload, sessionID: subject)
    }
}

extension CustomInstrumentOp: OutboxOp {
    public static let outboxFamily = "custom-instrument"

    public var outboxSubject: UUID { defID }

    public static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> CustomInstrumentOp? {
        fromJSON(payload)
    }
}

extension PatternSourceOp: OutboxOp {
    public static let outboxFamily = "pattern"

    public var outboxSubject: UUID { sourceID }

    public static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> PatternSourceOp? {
        fromJSON(payload)
    }
}

extension MissionOp: OutboxOp {
    public static let outboxFamily = "mission"

    public var outboxSubject: UUID { missionID }

    public static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> MissionOp? {
        fromJSON(payload)
    }
}

extension AddressNoteOp: OutboxOp {
    public static let outboxFamily = "address-note"

    public var outboxSubject: UUID { noteID }

    public static func fromOutbox(_ payload: [String: Any], subject: UUID, binary: Data?) -> AddressNoteOp? {
        fromJSON(payload)
    }
}
