import Foundation
import GRDB

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

public struct ObjectChat: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "object_chat"

    public var id: UUID
    public var title: String?
    public var subject: Subject
    public var sessionID: UUID?
    public var editors: [Author]
    public var createdAt: Date
    public var updatedAt: Date

    public var creator: Author? { editors.first }

    public enum Subject: Codable, Sendable, Equatable {
        case project
        case instruction(sessionID: UUID, anchor: AddressAnchor)
        case object(origin: Origin, label: String, source: String?, className: String, printString: String, snapshot: PharoSnapshot?)

        enum InstructionCodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case anchor
        }

        enum ObjectCodingKeys: String, CodingKey {
            case origin
            case label
            case source
            case className = "class_name"
            case printString = "print_string"
            case snapshot
        }

        public var sessionID: UUID? {
            switch self {
            case .project:
                nil
            case .instruction(let sessionID, _):
                sessionID
            case .object(let origin, _, _, _, _, _):
                origin.sessionID
            }
        }
    }

    public enum Origin: Codable, Sendable, Equatable {
        case snippet(snippetID: UUID)
        case notebookEntry(entryID: UUID)
        case instrumentView(instanceID: UUID, widget: String, sessionID: UUID)
        case chat(chatID: UUID, objectID: String)

        enum CodingKeys: String, CodingKey {
            case snippet
            case notebookEntry = "notebook_entry"
            case instrumentView = "instrument_view"
            case chat
        }

        enum SnippetCodingKeys: String, CodingKey {
            case snippetID = "snippet_id"
        }

        enum NotebookEntryCodingKeys: String, CodingKey {
            case entryID = "entry_id"
        }

        enum InstrumentViewCodingKeys: String, CodingKey {
            case instanceID = "instance_id"
            case widget
            case sessionID = "session_id"
        }

        enum ChatCodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case objectID = "object_id"
        }

        public var sessionID: UUID? {
            if case .instrumentView(_, _, let sessionID) = self { return sessionID }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subject
        case sessionID = "session_id"
        case editors
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static let soloConversationID = conversationID(named: "luma:project:conversation")

    public static func conversationID(ofLab labID: String) -> UUID {
        conversationID(named: "luma:lab:\(labID):conversation")
    }

    private static func conversationID(named name: String) -> UUID {
        let namespace = withUnsafeBytes(of: urlNamespace.uuid) { Array($0) }
        var digest = Array(Insecure.SHA1.hash(data: Data(namespace + Array(name.utf8))).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
    }

    private static let urlNamespace = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!

    public init(id: UUID = UUID(), title: String?, subject: Subject, editors: [Author]) {
        let now = Date()
        self.id = id
        self.title = title
        self.subject = subject
        self.sessionID = subject.sessionID
        self.editors = editors
        self.createdAt = now
        self.updatedAt = now
    }
}
