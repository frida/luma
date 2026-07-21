import Foundation

/// What the host hands the image, one record per thing rather than a line of
/// text, so the image can open one up and ask it questions.
public struct PharoHostRecord: Codable, Sendable {
    /// What the image shows when it prints the record.
    public let headline: String
    /// Base64 PNG, which is how a picture reaches the image.
    public var icon: String?
    public let fields: [String: String]

    public init(headline: String, icon: String? = nil, fields: [String: String]) {
        self.headline = headline
        self.icon = icon
        self.fields = fields
    }
}

extension ProcessSession {
    public var recordForPharo: PharoHostRecord {
        PharoHostRecord(
            headline: processName,
            icon: iconPNGData?.base64EncodedString(),
            fields: [
                "id": id.uuidString,
                "process": processName,
                "device": deviceName,
                "phase": String(describing: phase),
                "kind": String(describing: kind),
            ])
    }
}

extension NotebookEntry {
    public var recordForPharo: PharoHostRecord {
        PharoHostRecord(
            headline: title.isEmpty ? details : title,
            fields: [
                "id": id.uuidString,
                "kind": kind.rawValue,
                "title": title,
                "details": details,
                "timestamp": timestamp.formatted(.iso8601),
            ])
    }
}

extension RuntimeEvent {
    public var recordForPharo: PharoHostRecord {
        PharoHostRecord(
            headline: String(describing: payload),
            fields: [
                "id": id.uuidString,
                "timestamp": timestamp.formatted(.iso8601),
                "source": String(describing: source),
                "payload": String(describing: payload),
                "session": sessionID?.uuidString ?? "",
            ])
    }
}
