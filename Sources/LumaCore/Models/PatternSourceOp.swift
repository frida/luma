import Foundation

public enum PatternSourceOp: Sendable {
    case upsert(Upsert)
    case remove(Remove)

    public var opID: UUID {
        switch self {
        case .upsert(let u): return u.opID
        case .remove(let r): return r.opID
        }
    }

    public var sourceID: UUID {
        switch self {
        case .upsert(let u): return u.record.id
        case .remove(let r): return r.sourceID
        }
    }

    public var kind: String {
        switch self {
        case .upsert: return "upsert"
        case .remove: return "remove"
        }
    }

    public struct Upsert: Sendable {
        public let opID: UUID
        public var record: PatternSourceRecord

        public init(opID: UUID = UUID(), record: PatternSourceRecord) {
            self.opID = opID
            self.record = record
        }
    }

    public struct Remove: Sendable {
        public let opID: UUID
        public let sourceID: UUID

        public init(opID: UUID = UUID(), sourceID: UUID) {
            self.opID = opID
            self.sourceID = sourceID
        }
    }

    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = [
            "op_id": opID.uuidString,
            "kind": kind,
        ]
        switch self {
        case .upsert(let u):
            obj["source"] = u.record.toWireJSON()
        case .remove(let r):
            obj["source_id"] = r.sourceID.uuidString
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any]) -> PatternSourceOp? {
        guard let opIDStr = obj["op_id"] as? String,
            let opID = UUID(uuidString: opIDStr),
            let kind = obj["kind"] as? String
        else { return nil }

        switch kind {
        case "upsert":
            guard let sourceObj = obj["source"] as? [String: Any],
                let record = PatternSourceRecord.fromWireJSON(sourceObj)
            else { return nil }
            return .upsert(Upsert(opID: opID, record: record))
        case "remove":
            guard let sourceIDStr = obj["source_id"] as? String,
                let sourceID = UUID(uuidString: sourceIDStr)
            else { return nil }
            return .remove(Remove(opID: opID, sourceID: sourceID))
        default:
            return nil
        }
    }
}
