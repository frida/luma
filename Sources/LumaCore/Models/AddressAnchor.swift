import Foundation

public typealias JSONObject = [String: Any]

public enum AddressAnchor: Codable, Hashable {
    case absolute(UInt64)
    case moduleOffset(name: String, offset: UInt64)
    case moduleExport(name: String, export: String)

    public var displayString: String {
        switch self {
        case .absolute(let a):
            return String(format: "0x%llx", a)

        case .moduleOffset(let name, let offset):
            return "\(name)+\(String(format: "0x%llx", offset))"

        case .moduleExport(let name, let export):
            return "\(name)!\(export)"
        }
    }

    public func toJSON() -> JSONObject {
        switch self {
        case .absolute(let a):
            return [
                "type": "absolute",
                "address": a,
            ]

        case .moduleOffset(let name, let offset):
            return [
                "type": "moduleOffset",
                "name": name,
                "offset": offset,
            ]

        case .moduleExport(let name, let export):
            return [
                "type": "moduleExport",
                "name": name,
                "export": export,
            ]
        }
    }
}
