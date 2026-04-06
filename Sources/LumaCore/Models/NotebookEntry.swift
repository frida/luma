import Foundation

public struct NotebookEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var title: String
    public var details: String
    public var jsValue: JSInspectValue?
    public var binaryData: Data?
    public var sessionID: UUID?
    public var processName: String?
    public var isUserNote: Bool

    public init(
        id: UUID = UUID(),
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
        self.timestamp = timestamp
        self.title = title
        self.details = details
        self.jsValue = jsValue
        self.binaryData = binaryData
        self.sessionID = sessionID
        self.processName = processName
        self.isUserNote = isUserNote
    }

    public func toJSON() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var obj: [String: Any] = [
            "id": id.uuidString,
            "timestamp": formatter.string(from: timestamp),
            "title": title,
            "details": details,
            "is-user-note": isUserNote,
        ]

        if let processName {
            obj["process-name"] = processName
        }

        if let val = jsValue,
            let data = try? JSONEncoder().encode(val),
            let jsonObject = try? JSONSerialization.jsonObject(with: data)
        {
            obj["js-value"] = jsonObject
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
            let details = obj["details"] as? String
        else {
            return nil
        }

        var jsValue: JSInspectValue? = nil
        if let raw = obj["js-value"] {
            if let data = try? JSONSerialization.data(withJSONObject: raw),
                let decoded = try? JSONDecoder().decode(JSInspectValue.self, from: data)
            {
                jsValue = decoded
            }
        }

        let isUserNote = (obj["is-user-note"] as? Bool) ?? true
        let processName = obj["process-name"] as? String

        return NotebookEntry(
            id: uuid,
            timestamp: ts,
            title: title,
            details: details,
            jsValue: jsValue,
            binaryData: data.map { Data($0) },
            processName: processName,
            isUserNote: isUserNote
        )
    }
}
