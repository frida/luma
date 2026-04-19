import Foundation
import GRDB

public struct NotebookEntry: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notebook_entry"

    public enum Kind: String, Codable, Sendable { case note, capture }

    public struct Author: Codable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let avatarURL: String

        public init(id: String, name: String, avatarURL: String) {
            self.id = id
            self.name = name
            self.avatarURL = avatarURL
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case avatarURL = "avatar_url"
        }
    }

    public var id: UUID
    public var author: Author?
    public var kind: Kind
    public var timestamp: Date
    public var title: String
    public var details: String
    public var jsValue: JSInspectValue?
    public var binaryData: Data?
    public var sessionID: UUID?
    public var processName: String?

    /// True when the entry is a user-authored note (vs. a capture from an
    /// instrumented process). Maintained as a computed alias for the
    /// `kind` enum so existing callers don't have to churn.
    public var isUserNote: Bool {
        get { kind == .note }
        set { kind = newValue ? .note : .capture }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case kind
        case timestamp
        case title
        case details
        case jsValue = "js_value"
        case binaryData = "binary_data"
        case sessionID = "session_id"
        case processName = "process_name"
    }

    public init(
        id: UUID = UUID(),
        author: Author? = nil,
        timestamp: Date = .now,
        title: String,
        details: String,
        jsValue: JSInspectValue? = nil,
        binaryData: Data? = nil,
        sessionID: UUID? = nil,
        processName: String? = nil,
        isUserNote: Bool = false
    ) {
        self.id = id
        self.author = author
        self.kind = isUserNote ? .note : .capture
        self.timestamp = timestamp
        self.title = title
        self.details = details
        self.jsValue = jsValue
        self.binaryData = binaryData
        self.sessionID = sessionID
        self.processName = processName
    }

    public func toJSON() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var obj: [String: Any] = [
            "id": id.uuidString,
            "kind": kind.rawValue,
            "timestamp": formatter.string(from: timestamp),
            "title": title,
            "details": details,
        ]

        if let author {
            obj["author"] = [
                "id": author.id,
                "name": author.name,
                "avatar": author.avatarURL,
            ]
        }

        if let processName {
            obj["process_name"] = processName
        }

        if let val = jsValue,
            let data = try? JSONEncoder().encode(val),
            let jsonObject = try? JSONSerialization.jsonObject(with: data)
        {
            obj["js_value"] = jsonObject
        }

        return obj
    }

    public static func fromJSON(_ obj: [String: Any], binaryData data: [UInt8]?) -> NotebookEntry? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard
            let idString = obj["id"] as? String,
            let uuid = UUID(uuidString: idString),
            let timestampString = obj["timestamp"] as? String,
            let ts = formatter.date(from: timestampString),
            let title = obj["title"] as? String,
            let details = obj["details"] as? String,
            let kindRaw = obj["kind"] as? String,
            let kind = Kind(rawValue: kindRaw)
        else {
            return nil
        }

        var author: Author? = nil
        if let authorObj = obj["author"] as? [String: Any],
            let authorId = authorObj["id"] as? String,
            let authorName = authorObj["name"] as? String {
            let avatar = (authorObj["avatar"] as? String) ?? ""
            author = Author(id: authorId, name: authorName, avatarURL: avatar)
        }

        var jsValue: JSInspectValue? = nil
        if let raw = obj["js_value"] {
            if let data = try? JSONSerialization.data(withJSONObject: raw),
                let decoded = try? JSONDecoder().decode(JSInspectValue.self, from: data)
            {
                jsValue = decoded
            }
        }

        let processName = obj["process_name"] as? String

        return NotebookEntry(
            id: uuid,
            author: author,
            timestamp: ts,
            title: title,
            details: details,
            jsValue: jsValue,
            binaryData: data.map { Data($0) },
            processName: processName,
            isUserNote: kind == .note
        )
    }
}
