import Foundation

public enum AddressNoteOp: Sendable {
    case noteUpsert(NoteUpsert)
    case noteRemove(NoteRemove)
    case messageAppend(MessageAppend)
    case messageEdit(MessageEdit)

    public var opID: UUID {
        switch self {
        case .noteUpsert(let u): return u.opID
        case .noteRemove(let r): return r.opID
        case .messageAppend(let a): return a.opID
        case .messageEdit(let e): return e.opID
        }
    }

    public var noteID: UUID {
        switch self {
        case .noteUpsert(let u): return u.note.id
        case .noteRemove(let r): return r.noteID
        case .messageAppend(let a): return a.message.noteID
        case .messageEdit(let e): return e.noteID
        }
    }

    public var kind: String {
        switch self {
        case .noteUpsert: return "address_note_upsert"
        case .noteRemove: return "address_note_remove"
        case .messageAppend: return "address_note_message_append"
        case .messageEdit: return "address_note_message_edit"
        }
    }

    public struct NoteUpsert: Sendable {
        public let opID: UUID
        public var note: AddressNote

        public init(opID: UUID = UUID(), note: AddressNote) {
            self.opID = opID
            self.note = note
        }
    }

    public struct NoteRemove: Sendable {
        public let opID: UUID
        public let noteID: UUID

        public init(opID: UUID = UUID(), noteID: UUID) {
            self.opID = opID
            self.noteID = noteID
        }
    }

    public struct MessageAppend: Sendable {
        public let opID: UUID
        public let message: AddressNoteMessage

        public init(opID: UUID = UUID(), message: AddressNoteMessage) {
            self.opID = opID
            self.message = message
        }
    }

    public struct MessageEdit: Sendable {
        public let opID: UUID
        public let noteID: UUID
        public let messageID: UUID
        public let bodyMarkdown: String

        public init(opID: UUID = UUID(), noteID: UUID, messageID: UUID, bodyMarkdown: String) {
            self.opID = opID
            self.noteID = noteID
            self.messageID = messageID
            self.bodyMarkdown = bodyMarkdown
        }
    }

    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = [
            "op_id": opID.uuidString,
            "kind": kind,
        ]
        switch self {
        case .noteUpsert(let u):
            obj["note"] = encodeRow(u.note)
        case .noteRemove(let r):
            obj["note_id"] = r.noteID.uuidString
        case .messageAppend(let a):
            obj["message"] = encodeRow(a.message)
        case .messageEdit(let e):
            obj["note_id"] = e.noteID.uuidString
            obj["message_id"] = e.messageID.uuidString
            obj["body_markdown"] = e.bodyMarkdown
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any]) -> AddressNoteOp? {
        guard let opIDStr = obj["op_id"] as? String,
            let opID = UUID(uuidString: opIDStr),
            let kind = obj["kind"] as? String
        else { return nil }

        switch kind {
        case "address_note_upsert":
            guard let row = obj["note"] as? [String: Any],
                let note: AddressNote = decodeRow(row)
            else { return nil }
            return .noteUpsert(NoteUpsert(opID: opID, note: note))
        case "address_note_remove":
            guard let idStr = obj["note_id"] as? String,
                let id = UUID(uuidString: idStr)
            else { return nil }
            return .noteRemove(NoteRemove(opID: opID, noteID: id))
        case "address_note_message_append":
            guard let row = obj["message"] as? [String: Any],
                let message: AddressNoteMessage = decodeRow(row)
            else { return nil }
            return .messageAppend(MessageAppend(opID: opID, message: message))
        case "address_note_message_edit":
            guard let nIDStr = obj["note_id"] as? String,
                let nID = UUID(uuidString: nIDStr),
                let mIDStr = obj["message_id"] as? String,
                let mID = UUID(uuidString: mIDStr),
                let body = obj["body_markdown"] as? String
            else { return nil }
            return .messageEdit(MessageEdit(opID: opID, noteID: nID, messageID: mID, bodyMarkdown: body))
        default:
            return nil
        }
    }
}

private let wireEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private let wireDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

private func encodeRow<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? wireEncoder.encode(value),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

private func decodeRow<T: Decodable>(_ obj: [String: Any]) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
        let value = try? wireDecoder.decode(T.self, from: data)
    else { return nil }
    return value
}
