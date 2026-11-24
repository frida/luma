import Foundation

public struct ObjectChatOp: Sendable {
    public let opID: UUID
    public let change: Change

    public enum Change: Sendable {
        case chatUpsert(ObjectChat)
        case chatRemove(chatID: UUID)
        case messageAppend(ObjectChatMessage)
        case messageEdit(chatID: UUID, messageID: UUID, bodyMarkdown: String)
        case messageRemove(chatID: UUID, messageID: UUID)
        case toolCallUpsert(ObjectChatToolCall)
        case objectUpsert(ObjectChatObject)
    }

    public init(opID: UUID = UUID(), _ change: Change) {
        self.opID = opID
        self.change = change
    }

    public static let snapshotByteLimit = 512 * 1024

    public var chatID: UUID {
        switch change {
        case .chatUpsert(let chat): chat.id
        case .chatRemove(let chatID): chatID
        case .messageAppend(let message): message.chatID
        case .messageEdit(let chatID, _, _): chatID
        case .messageRemove(let chatID, _): chatID
        case .toolCallUpsert(let call): call.chatID
        case .objectUpsert(let object): object.chatID
        }
    }

    public var kind: String {
        switch change {
        case .chatUpsert: "object_chat_upsert"
        case .chatRemove: "object_chat_remove"
        case .messageAppend: "object_chat_message_append"
        case .messageEdit: "object_chat_message_edit"
        case .messageRemove: "object_chat_message_remove"
        case .toolCallUpsert: "object_chat_tool_call_upsert"
        case .objectUpsert: "object_chat_object_upsert"
        }
    }

    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = ["op_id": opID.uuidString, "kind": kind]
        switch change {
        case .chatUpsert(let chat):
            obj["chat"] = Self.withinSnapshotLimit(encodeRow(chat), at: ["subject", "object", "snapshot"])
        case .chatRemove(let chatID):
            obj["chat_id"] = chatID.uuidString
        case .messageAppend(let message):
            obj["message"] = encodeRow(message)
        case .messageEdit(let chatID, let messageID, let bodyMarkdown):
            obj["chat_id"] = chatID.uuidString
            obj["message_id"] = messageID.uuidString
            obj["body_markdown"] = bodyMarkdown
        case .messageRemove(let chatID, let messageID):
            obj["chat_id"] = chatID.uuidString
            obj["message_id"] = messageID.uuidString
        case .toolCallUpsert(let call):
            obj["tool_call"] = encodeRow(call)
        case .objectUpsert(let object):
            obj["object"] = Self.withinSnapshotLimit(encodeRow(object), at: ["snapshot"])
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any]) -> ObjectChatOp? {
        guard let opID = (obj["op_id"] as? String).flatMap(UUID.init(uuidString:)),
            let change = change(of: obj)
        else { return nil }
        return ObjectChatOp(opID: opID, change)
    }

    private static func change(of obj: [String: Any]) -> Change? {
        let chatID = (obj["chat_id"] as? String).flatMap(UUID.init(uuidString:))
        let messageID = (obj["message_id"] as? String).flatMap(UUID.init(uuidString:))
        switch obj["kind"] as? String {
        case "object_chat_upsert":
            return (obj["chat"] as? [String: Any]).flatMap(decodeRow).map(Change.chatUpsert)
        case "object_chat_remove":
            return chatID.map { .chatRemove(chatID: $0) }
        case "object_chat_message_append":
            return (obj["message"] as? [String: Any]).flatMap(decodeRow).map(Change.messageAppend)
        case "object_chat_message_edit":
            guard let chatID, let messageID, let body = obj["body_markdown"] as? String else { return nil }
            return .messageEdit(chatID: chatID, messageID: messageID, bodyMarkdown: body)
        case "object_chat_message_remove":
            guard let chatID, let messageID else { return nil }
            return .messageRemove(chatID: chatID, messageID: messageID)
        case "object_chat_tool_call_upsert":
            return (obj["tool_call"] as? [String: Any]).flatMap(decodeRow).map(Change.toolCallUpsert)
        case "object_chat_object_upsert":
            return (obj["object"] as? [String: Any]).flatMap(decodeRow).map(Change.objectUpsert)
        default:
            return nil
        }
    }

    private static func withinSnapshotLimit(_ row: [String: Any], at path: [String]) -> [String: Any] {
        guard let key = path.first, var nested = row[key] as? [String: Any] else { return row }
        var trimmed = row
        if path.count == 1 {
            if let data = try? JSONSerialization.data(withJSONObject: nested), data.count > snapshotByteLimit {
                trimmed[key] = nil
            }
            return trimmed
        }
        nested = withinSnapshotLimit(nested, at: Array(path.dropFirst()))
        trimmed[key] = nested
        return trimmed
    }
}

public struct ObjectChatThread: Sendable {
    public let chat: ObjectChat
    public let messages: [ObjectChatMessage]
    public let toolCalls: [ObjectChatToolCall]
    public let objects: [ObjectChatObject]
    public let historyFrom: Int

    public static func fromWireJSON(_ obj: [String: Any]) -> ObjectChatThread? {
        guard let chat: ObjectChat = decodeRow(obj) else { return nil }
        return ObjectChatThread(
            chat: chat,
            messages: rows(obj["messages"]),
            toolCalls: rows(obj["tool_calls"]),
            objects: rows(obj["objects"]),
            historyFrom: obj["history_from"] as? Int ?? 0
        )
    }

    private static func rows<T: Decodable>(_ value: Any?) -> [T] {
        ((value as? [[String: Any]]) ?? []).compactMap { decodeRow($0) }
    }
}
