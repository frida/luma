import Foundation
import GRDB

public struct NotebookEntry: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notebook_entry"

    public enum Kind: String, Codable, Sendable {
        /// User-authored freeform note.
        case note
        /// Captured from an instrumented process via a hook / script.
        case capture
    }

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
    public var kind: Kind
    /// Original creator at index 0, followed by everyone who's edited the
    /// entry (deduped, preserving first-edit order). The server appends on
    /// each `update` op it applies.
    public var editors: [Author]
    public var timestamp: Date
    /// Server-authoritative sort key. New entries get `(current max + 1000)`;
    /// drag operations slot in at the midpoint of two neighbors. Clients
    /// sort by `(position, id)` so ties break deterministically.
    public var position: Double
    public var title: String
    public var details: String
    public var jsValue: JSInspectValue?
    public var binaryData: Data?
    public var sessionID: UUID?
    public var processName: String?

    public var author: Author? { editors.first }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case editors
        case timestamp
        case position
        case title
        case details
        case jsValue = "js_value"
        case binaryData = "binary_data"
        case sessionID = "session_id"
        case processName = "process_name"
    }

    public init(
        id: UUID = UUID(),
        kind: Kind = .capture,
        editors: [Author] = [],
        timestamp: Date = .now,
        position: Double = 0,
        title: String,
        details: String,
        jsValue: JSInspectValue? = nil,
        binaryData: Data? = nil,
        sessionID: UUID? = nil,
        processName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.editors = editors
        self.timestamp = timestamp
        self.position = position
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
            "editors": editors.map { author in
                [
                    "id": author.id,
                    "name": author.name,
                    "avatar": author.avatarURL,
                ]
            },
            "timestamp": formatter.string(from: timestamp),
            "position": position,
            "title": title,
            "details": details,
        ]

        if let val = jsValue,
            let data = try? JSONEncoder().encode(val),
            let jsonObject = try? JSONSerialization.jsonObject(with: data)
        {
            obj["js_value"] = jsonObject
        }

        if let processName {
            obj["process_name"] = processName
        }

        return obj
    }

    public static func fromJSON(_ obj: [String: Any], binaryData data: [UInt8]?) -> NotebookEntry? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard
            let idString = obj["id"] as? String,
            let uuid = UUID(uuidString: idString),
            let kindRaw = obj["kind"] as? String,
            let kind = Kind(rawValue: kindRaw),
            let timestampString = obj["timestamp"] as? String,
            let ts = formatter.date(from: timestampString),
            let title = obj["title"] as? String,
            let details = obj["details"] as? String
        else {
            return nil
        }

        var editors: [Author] = []
        if let arr = obj["editors"] as? [[String: Any]] {
            for item in arr {
                guard let id = item["id"] as? String,
                    let name = item["name"] as? String else { continue }
                let avatar = (item["avatar"] as? String) ?? ""
                editors.append(Author(id: id, name: name, avatarURL: avatar))
            }
        }

        let position = (obj["position"] as? Double)
            ?? (obj["position"] as? NSNumber)?.doubleValue
            ?? 0

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
            kind: kind,
            editors: editors,
            timestamp: ts,
            position: position,
            title: title,
            details: details,
            jsValue: jsValue,
            binaryData: data.map { Data($0) },
            processName: processName
        )
    }
}
