import Foundation

/// What the host hands the image, one record per thing rather than a line of
/// text, so the image can open one up and ask it questions.
public struct PharoHostRecord: Sendable {
    public let headline: String
    /// Base64 PNG, which is how a picture reaches the image.
    public var icon: String?
    public let fields: [String: String]

    public init(headline: String, icon: String? = nil, fields: [String: String]) {
        self.headline = headline
        self.icon = icon
        self.fields = fields
    }

    public var json: [String: Any] {
        var object: [String: Any] = ["headline": headline, "fields": fields]
        if let icon {
            object["icon"] = icon
        }
        return object
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
        let payload = logPayload
        return PharoHostRecord(
            headline: headlineForPharo(of: payload),
            fields: [
                "id": id.uuidString,
                "timestamp": timestamp.formatted(.iso8601),
                "source": String(describing: source),
                "payload": jsonText(of: payload),
                "session": sessionID?.uuidString ?? "",
            ])
    }

    private func headlineForPharo(of payload: [String: Any]) -> String {
        guard case .raw = self.payload else { return String(describing: self.payload) }
        return jsonText(of: sentPayload ?? payload["value"] ?? "")
    }

    var sentPayload: Any? {
        guard case .raw(let message, _) = payload, let envelope = message as? [String: Any],
            envelope["type"] as? String == "send"
        else { return nil }
        return envelope["payload"]
    }

    private func jsonText(of value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
