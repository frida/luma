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
        case spawnGating(deviceID: String, deviceName: String, identifier: String?, pid: UInt, outcome: SpawnGatingOutcome)
        case engine(subsystem: String)
    }

    public enum SpawnGatingOutcome: String, Sendable {
        case captured
        case released
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

    public func toLogJSON() -> [String: Any]? {
        guard let sourceObj = Self.encodeSource(source) else { return nil }
        var obj: [String: Any] = [
            "id": id.uuidString,
            "timestamp": Self.wireFormatter.string(from: timestamp),
            "source": sourceObj,
            "payload": Self.encodePayloadForLog(payload),
        ]
        if let sessionID {
            obj["sessionID"] = sessionID.uuidString
        }
        if let data {
            obj["data"] = Data(data).base64EncodedString()
        }
        return obj
    }

    public static func fromLogJSON(_ obj: [String: Any]) -> RuntimeEvent? {
        guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr),
            let timestampStr = obj["timestamp"] as? String,
            let timestamp = wireFormatter.date(from: timestampStr),
            let sourceObj = obj["source"] as? [String: Any],
            let source = decodeSource(sourceObj),
            let payloadObj = obj["payload"] as? [String: Any],
            let payload = decodePayloadForLog(payloadObj)
        else { return nil }
        let sessionID: UUID? = (obj["sessionID"] as? String).flatMap(UUID.init)
        let data: [UInt8]?
        if let dataStr = obj["data"] as? String,
            let bytes = Data(base64Encoded: dataStr) {
            data = Array(bytes)
        } else {
            data = nil
        }
        return RuntimeEvent(
            id: id, timestamp: timestamp, sessionID: sessionID,
            source: source, payload: payload, data: data
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
        case .spawnGating(let deviceID, let deviceName, let identifier, let pid, let outcome):
            var dict: [String: Any] = [
                "kind": "spawn-gating",
                "device_id": deviceID,
                "device_name": deviceName,
                "pid": pid,
                "outcome": outcome.rawValue,
            ]
            if let identifier { dict["identifier"] = identifier }
            return dict
        case .engine(let subsystem):
            return ["kind": "engine", "subsystem": subsystem]
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
        case "spawn-gating":
            guard let deviceID = obj["device_id"] as? String,
                let deviceName = obj["device_name"] as? String,
                let pid = obj["pid"] as? UInt,
                let outcomeRaw = obj["outcome"] as? String,
                let outcome = SpawnGatingOutcome(rawValue: outcomeRaw)
            else { return nil }
            let identifier = obj["identifier"] as? String
            return .spawnGating(
                deviceID: deviceID,
                deviceName: deviceName,
                identifier: identifier,
                pid: pid,
                outcome: outcome
            )
        case "engine":
            guard let subsystem = obj["subsystem"] as? String else { return nil }
            return .engine(subsystem: subsystem)
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

    private static func encodePayloadForLog(_ payload: Payload) -> [String: Any] {
        if let wire = encodePayload(payload) { return wire }
        guard case .raw(let message, let data) = payload else { return ["kind": "raw", "value": ""] }
        return ["kind": "raw", "value": serializableMessage(message), "hasInlineData": data != nil]
    }

    private static func decodePayloadForLog(_ obj: [String: Any]) -> Payload? {
        if let wire = decodePayload(obj) { return wire }
        guard let kind = obj["kind"] as? String, kind == "raw" else { return nil }
        let message = obj["value"] ?? ""
        return .raw(message: message, data: nil)
    }

    private static func serializableMessage(_ message: Any) -> Any {
        if let s = message as? String { return s }
        if let n = message as? NSNumber { return n }
        if JSONSerialization.isValidJSONObject(message) { return message }
        if let dict = message as? [String: Any], JSONSerialization.isValidJSONObject(dict) { return dict }
        if let arr = message as? [Any], JSONSerialization.isValidJSONObject(arr) { return arr }
        return String(describing: message)
    }
}
