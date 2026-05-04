import Foundation

public struct RuntimeEvent: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var sessionID: UUID?
    public let source: Source
    public let payload: Payload
    public let data: [UInt8]?

    public enum Source: Sendable {
        case processOutput(fd: Int)
        case script
        case console
        case repl
        case instrument(id: UUID, name: String)
    }

    public enum Payload: @unchecked Sendable {
        case consoleMessage(ConsoleMessage)
        case jsError(JSError)
        case jsValue(JSInspectValue)
        case raw(message: Any, data: [UInt8]?)
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        sessionID: UUID? = nil,
        source: Source,
        payload: Payload,
        data: [UInt8]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.source = source
        self.payload = payload
        self.data = data
    }

    nonisolated(unsafe) private static let wireFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func toWireJSON() -> [String: Any]? {
        guard let sourceObj = Self.encodeSource(source),
            let payloadObj = Self.encodePayload(payload)
        else { return nil }
        var obj: [String: Any] = [
            "id": id.uuidString,
            "timestamp": Self.wireFormatter.string(from: timestamp),
            "source": sourceObj,
            "payload": payloadObj,
        ]
        if let data {
            obj["data"] = Data(data).base64EncodedString()
        }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> RuntimeEvent? {
        guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr),
            let timestampStr = obj["timestamp"] as? String,
            let timestamp = wireFormatter.date(from: timestampStr),
            let sourceObj = obj["source"] as? [String: Any],
            let source = decodeSource(sourceObj),
            let payloadObj = obj["payload"] as? [String: Any],
            let payload = decodePayload(payloadObj)
        else { return nil }
        let data: [UInt8]?
        if let dataStr = obj["data"] as? String,
            let bytes = Data(base64Encoded: dataStr) {
            data = Array(bytes)
        } else {
            data = nil
        }
        return RuntimeEvent(
            id: id, timestamp: timestamp, source: source,
            payload: payload, data: data
        )
    }

    private static func encodeSource(_ source: Source) -> [String: Any]? {
        switch source {
        case .processOutput(let fd):
            return ["kind": "process-output", "fd": fd]
        case .script:
            return ["kind": "script"]
        case .console:
            return ["kind": "console"]
        case .repl:
            return ["kind": "repl"]
        case .instrument(let id, let name):
            return ["kind": "instrument", "id": id.uuidString, "name": name]
        }
    }

    private static func decodeSource(_ obj: [String: Any]) -> Source? {
        guard let kind = obj["kind"] as? String else { return nil }
        switch kind {
        case "process-output":
            guard let fd = obj["fd"] as? Int else { return nil }
            return .processOutput(fd: fd)
        case "script":
            return .script
        case "console":
            return .console
        case "repl":
            return .repl
        case "instrument":
            guard let idStr = obj["id"] as? String,
                let id = UUID(uuidString: idStr),
                let name = obj["name"] as? String
            else { return nil }
            return .instrument(id: id, name: name)
        default:
            return nil
        }
    }

    private static let payloadEncoder = JSONEncoder()
    private static let payloadDecoder = JSONDecoder()

    private static func encodePayload(_ payload: Payload) -> [String: Any]? {
        switch payload {
        case .consoleMessage(let msg):
            guard let data = try? payloadEncoder.encode(msg),
                let body = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return ["kind": "console-message", "value": body]
        case .jsError(let err):
            guard let data = try? payloadEncoder.encode(err),
                let body = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return ["kind": "js-error", "value": body]
        case .jsValue(let value):
            guard let data = try? payloadEncoder.encode(value),
                let body = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return ["kind": "js-value", "value": body]
        case .raw:
            return nil
        }
    }

    private static func decodePayload(_ obj: [String: Any]) -> Payload? {
        guard let kind = obj["kind"] as? String, let value = obj["value"] else { return nil }
        switch kind {
        case "console-message":
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                let msg = try? payloadDecoder.decode(ConsoleMessage.self, from: data)
            else { return nil }
            return .consoleMessage(msg)
        case "js-error":
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                let err = try? payloadDecoder.decode(JSError.self, from: data)
            else { return nil }
            return .jsError(err)
        case "js-value":
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                let v = try? payloadDecoder.decode(JSInspectValue.self, from: data)
            else { return nil }
            return .jsValue(v)
        default:
            return nil
        }
    }
}
