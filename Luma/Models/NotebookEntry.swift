import Foundation
import SwiftData

@Model
class NotebookEntry {
    var id: UUID
    var timestamp: Date
    var title: String
    var details: String

    @Attribute(.externalStorage)
    private var jsValueData: Data?

    @Attribute(.externalStorage)
    var binaryData: Data?

    var processName: String?
    var isUserNote: Bool

    var jsValue: JSInspectValue? {
        get {
            guard let jsValueData else { return nil }
            return try? JSONDecoder().decode(JSInspectValue.self, from: jsValueData)
        }
        set {
            if let v = newValue {
                jsValueData = try? JSONEncoder().encode(v)
            } else {
                jsValueData = nil
            }
        }
    }

    convenience init(
        title: String,
        details: String,
        jsValue: JSInspectValue? = nil,
        binaryData: Data? = nil,
        processName: String? = nil,
        isUserNote: Bool = false
    ) {
        self.init(
            id: UUID(),
            timestamp: Date(),
            title: title,
            details: details,
            jsValue: jsValue,
            binaryData: binaryData,
            processName: processName,
            isUserNote: isUserNote,
        )
    }

    init(
        id: UUID,
        timestamp: Date,
        title: String,
        details: String,
        jsValue: JSInspectValue? = nil,
        binaryData: Data? = nil,
        processName: String? = nil,
        isUserNote: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.details = details
        self.binaryData = binaryData
        self.processName = processName
        self.isUserNote = isUserNote

        self.jsValue = jsValue
    }

    func toJSON() -> [String: Any] {
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

    static func fromJSON(_ obj: [String: Any], binaryData data: [UInt8]?) -> NotebookEntry? {
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
