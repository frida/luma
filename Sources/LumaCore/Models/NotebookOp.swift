import Foundation

/// A single pending mutation against a lab's notebook. Ops are the atomic
/// unit of the collaboration protocol: clients persist them into the
/// outbox as they happen, the server deduplicates by `opID`, applies, and
/// broadcasts the authoritative result back (including the server-stamped
/// `editors` and `position`).
public enum NotebookOp: Sendable {
    case add(Add)
    case update(Update)
    case remove(Remove)
    case reorder(Reorder)

    public var opID: UUID {
        switch self {
        case .add(let a): return a.opID
        case .update(let u): return u.opID
        case .remove(let r): return r.opID
        case .reorder(let r): return r.opID
        }
    }

    public var entryID: UUID {
        switch self {
        case .add(let a): return a.entry.id
        case .update(let u): return u.entryID
        case .remove(let r): return r.entryID
        case .reorder(let r): return r.entryID
        }
    }

    public var kind: String {
        switch self {
        case .add: return "add"
        case .update: return "update"
        case .remove: return "remove"
        case .reorder: return "reorder"
        }
    }

    public struct Add: Sendable {
        public let opID: UUID
        public var entry: NotebookEntry

        public init(opID: UUID = UUID(), entry: NotebookEntry) {
            self.opID = opID
            self.entry = entry
        }
    }

    public struct Update: Sendable {
        public let opID: UUID
        public let entryID: UUID
        public var title: String?
        public var details: String?
        public var processName: String?

        public init(
            opID: UUID = UUID(),
            entryID: UUID,
            title: String? = nil,
            details: String? = nil,
            processName: String? = nil
        ) {
            self.opID = opID
            self.entryID = entryID
            self.title = title
            self.details = details
            self.processName = processName
        }

        public var changes: [String: String] {
            var out: [String: String] = [:]
            if let title { out["title"] = title }
            if let details { out["details"] = details }
            if let processName { out["process_name"] = processName }
            return out
        }
    }

    public struct Remove: Sendable {
        public let opID: UUID
        public let entryID: UUID

        public init(opID: UUID = UUID(), entryID: UUID) {
            self.opID = opID
            self.entryID = entryID
        }
    }

    public struct Reorder: Sendable {
        public let opID: UUID
        public let entryID: UUID
        public var position: Double

        public init(opID: UUID = UUID(), entryID: UUID, position: Double) {
            self.opID = opID
            self.entryID = entryID
            self.position = position
        }
    }

    /// Envelope payload for a `+op` notification. The accompanying bus
    /// message carries binary data for `add` ops in the standard way.
    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = [
            "op_id": opID.uuidString,
            "kind": kind,
        ]
        switch self {
        case .add(let a):
            obj["entry"] = a.entry.toJSON()
        case .update(let u):
            obj["entry_id"] = u.entryID.uuidString
            obj["changes"] = u.changes
        case .remove(let r):
            obj["entry_id"] = r.entryID.uuidString
        case .reorder(let r):
            obj["entry_id"] = r.entryID.uuidString
            obj["position"] = r.position
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any], binaryData: [UInt8]?) -> NotebookOp? {
        guard let opIDStr = obj["op_id"] as? String,
            let opID = UUID(uuidString: opIDStr),
            let kind = obj["kind"] as? String
        else {
            return nil
        }

        switch kind {
        case "add":
            guard let entryObj = obj["entry"] as? [String: Any],
                let entry = NotebookEntry.fromJSON(entryObj, binaryData: binaryData)
            else { return nil }
            return .add(Add(opID: opID, entry: entry))

        case "update":
            guard let entryIDStr = obj["entry_id"] as? String,
                let entryID = UUID(uuidString: entryIDStr),
                let changes = obj["changes"] as? [String: Any]
            else { return nil }
            return .update(Update(
                opID: opID,
                entryID: entryID,
                title: changes["title"] as? String,
                details: changes["details"] as? String,
                processName: changes["process_name"] as? String
            ))

        case "remove":
            guard let entryIDStr = obj["entry_id"] as? String,
                let entryID = UUID(uuidString: entryIDStr)
            else { return nil }
            return .remove(Remove(opID: opID, entryID: entryID))

        case "reorder":
            guard let entryIDStr = obj["entry_id"] as? String,
                let entryID = UUID(uuidString: entryIDStr),
                let position = (obj["position"] as? Double)
                    ?? (obj["position"] as? NSNumber)?.doubleValue
            else { return nil }
            return .reorder(Reorder(opID: opID, entryID: entryID, position: position))

        default:
            return nil
        }
    }
}
