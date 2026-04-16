import Foundation

public typealias JSONObject = [String: Any]

public enum AddressAnchor: Codable, Hashable, Sendable {
    case absolute(UInt64)
    case moduleOffset(name: String, offset: UInt64)
    case moduleExport(name: String, export: String)
    case objcMethod(selector: String)
    case swiftFunc(module: String, function: String)
    case debugSymbol(name: String)

    public var displayString: String {
        switch self {
        case .absolute(let a):
            return String(format: "0x%llx", a)

        case .moduleOffset(let name, let offset):
            return "\(name)+\(String(format: "0x%llx", offset))"

        case .moduleExport(let name, let export):
            return "\(name)!\(export)"

        case .objcMethod(let selector):
            return selector

        case .swiftFunc(let module, let function):
            return "\(module)!\(function)"

        case .debugSymbol(let name):
            return name
        }
    }

    public static func fromJSON(_ object: JSONObject) throws -> AddressAnchor {
        guard let type = object["type"] as? String else {
            throw LumaCoreError.invalidArgument("Anchor missing 'type'")
        }
        switch type {
        case "absolute":
            return .absolute(try parseAnchorAddress(object["address"]))
        case "moduleOffset":
            return .moduleOffset(
                name: try parseAnchorString(object["name"], field: "name"),
                offset: try parseAnchorOffset(object["offset"])
            )
        case "moduleExport":
            return .moduleExport(
                name: try parseAnchorString(object["name"], field: "name"),
                export: try parseAnchorString(object["export"], field: "export")
            )
        case "objcMethod":
            return .objcMethod(selector: try parseAnchorString(object["selector"], field: "selector"))
        case "swiftFunc":
            return .swiftFunc(
                module: try parseAnchorString(object["module"], field: "module"),
                function: try parseAnchorString(object["function"], field: "function")
            )
        case "debugSymbol":
            return .debugSymbol(name: try parseAnchorString(object["name"], field: "name"))
        default:
            throw LumaCoreError.invalidArgument("Unknown anchor type '\(type)'")
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

        case .objcMethod(let selector):
            return [
                "type": "objcMethod",
                "selector": selector,
            ]

        case .swiftFunc(let module, let function):
            return [
                "type": "swiftFunc",
                "module": module,
                "function": function,
            ]

        case .debugSymbol(let name):
            return [
                "type": "debugSymbol",
                "name": name,
            ]
        }
    }
}

private func parseAnchorString(_ value: Any?, field: String) throws -> String {
    guard let s = value as? String else {
        throw LumaCoreError.invalidArgument("Anchor field '\(field)' is not a String")
    }
    return s
}

private func parseAnchorAddress(_ value: Any?) throws -> UInt64 {
    if let u = value as? UInt64 {
        return u
    }
    if let s = value as? String {
        return try parseAgentHexAddress(s)
    }
    throw LumaCoreError.invalidArgument("Anchor 'address' is not a UInt64 or hex String")
}

private func parseAnchorOffset(_ value: Any?) throws -> UInt64 {
    if let u = value as? UInt64 {
        return u
    }
    if let n = value as? Double {
        return UInt64(n)
    }
    if let i = value as? Int {
        return UInt64(i)
    }
    throw LumaCoreError.invalidArgument("Anchor 'offset' is not numeric")
}
