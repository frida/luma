import Foundation

extension JSONEncoder {
    static let missionWire: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let missionWire: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension Mission {
    public func toWireJSON() -> [String: Any]? { encodeMissionEntity(self) }
    public static func fromWireJSON(_ obj: [String: Any]) -> Mission? { decodeMissionEntity(obj) }
}

extension MissionTarget {
    public func toWireJSON() -> [String: Any]? { encodeMissionEntity(self) }
    public static func fromWireJSON(_ obj: [String: Any]) -> MissionTarget? { decodeMissionEntity(obj) }
}

extension MissionTurn {
    public func toWireJSON() -> [String: Any]? { encodeMissionEntity(self) }
    public static func fromWireJSON(_ obj: [String: Any]) -> MissionTurn? { decodeMissionEntity(obj) }
}

extension MissionAction {
    public func toWireJSON() -> [String: Any]? { encodeMissionEntity(self) }
    public static func fromWireJSON(_ obj: [String: Any]) -> MissionAction? { decodeMissionEntity(obj) }
}

extension MissionFinding {
    public func toWireJSON() -> [String: Any]? { encodeMissionEntity(self) }
    public static func fromWireJSON(_ obj: [String: Any]) -> MissionFinding? { decodeMissionEntity(obj) }
}

extension MissionEvidence {
    public func toWireJSON() -> [String: Any]? { encodeMissionEntity(self) }
    public static func fromWireJSON(_ obj: [String: Any]) -> MissionEvidence? { decodeMissionEntity(obj) }
}

private func encodeMissionEntity<T: Encodable>(_ value: T) -> [String: Any]? {
    guard let data = try? JSONEncoder.missionWire.encode(value),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

private func decodeMissionEntity<T: Decodable>(_ obj: [String: Any]) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
        let value = try? JSONDecoder.missionWire.decode(T.self, from: data)
    else { return nil }
    return value
}
