import Foundation

public typealias JSONObject = [String: Any]

public enum AddressAnchor: Hashable, Sendable {
    case absolute(UInt64)
    case moduleOffset(name: String, offset: UInt64)
    case moduleExport(name: String, export: String)
    case objcMethod(selector: String)
    case swiftFunc(module: String, function: String)
    case debugSymbol(name: String)
    case javaMethod(className: String, methodName: String)

    public var moduleGroupName: String {
        switch self {
        case .moduleOffset(let name, _),
            .moduleExport(let name, _):
            return name
        case .swiftFunc(let module, _):
            return module
        case .objcMethod:
            return "Objective-C"
        case .javaMethod:
            return "Java"
        case .debugSymbol:
            return "Debug Symbols"
        case .absolute:
            return "Absolute Addresses"
        }
    }

    public var displayString: String {
        switch self {
        case .absolute(let a):
            return String(format: "0x%llx", a)

        case .moduleOffset(let name, let offset):
            return "\(moduleBasename(name))+\(String(format: "0x%llx", offset))"

        case .moduleExport(let name, let export):
            return "\(moduleBasename(name))!\(export)"

        case .objcMethod(let selector):
            return selector

        case .swiftFunc(let module, let function):
            return "\(moduleBasename(module))!\(function)"

        case .debugSymbol(let name):
            return name

        case .javaMethod(let className, let methodName):
            return "\(className).\(methodName)"
        }
    }

    public var symbolName: String {
        switch self {
        case .moduleExport(_, let export):
            return export
        case .swiftFunc(_, let function):
            return function
        default:
            return displayString
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
        case "javaMethod":
            return .javaMethod(
                className: try parseAnchorString(object["className"], field: "className"),
                methodName: try parseAnchorString(object["methodName"], field: "methodName")
            )
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

        case .javaMethod(let className, let methodName):
            return [
                "type": "javaMethod",
                "className": className,
                "methodName": methodName,
            ]
        }
    }
}

public enum HexAddress {
    public static let refusal = "an address is \"0x\" followed by lowercase hexadecimal digits without leading zeros, such as \"0x1f00\""

    public static func string(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    public static func parse(_ text: String) -> UInt64? {
        guard text.wholeMatch(of: /0x(0|[1-9a-f][0-9a-f]{0,15})/) != nil else { return nil }
        return UInt64(text.dropFirst(2), radix: 16)
    }

    static func decode<Key: CodingKey>(_ key: Key, from container: KeyedDecodingContainer<Key>) throws -> UInt64 {
        guard let value = parse(try container.decode(String.self, forKey: key)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: refusal)
        }
        return value
    }
}

public enum ModuleOffset {
    public static let refusal = "an offset is a whole number from 0 to \(Int64.max)"

    public static func value(_ raw: Any?) -> UInt64? {
        guard let whole = raw as? Int, whole >= 0 else { return nil }
        return UInt64(whole)
    }

    public static func number(_ offset: UInt64) -> Int {
        Int(offset)
    }

    static func decode<Key: CodingKey>(_ key: Key, from container: KeyedDecodingContainer<Key>) throws -> UInt64 {
        guard let whole = try? container.decode(Int64.self, forKey: key), whole >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: refusal)
        }
        return UInt64(whole)
    }
}

extension AddressAnchor: Codable {
    private enum Kind: String, CaseIterable {
        case absolute
        case moduleOffset = "module_offset"
        case moduleExport = "module_export"
        case objcMethod = "objc_method"
        case swiftFunc = "swift_func"
        case debugSymbol = "debug_symbol"
        case javaMethod = "java_method"

        var fields: Set<String> {
            switch self {
            case .absolute: ["address"]
            case .moduleOffset: ["name", "offset"]
            case .moduleExport: ["name", "export"]
            case .objcMethod: ["selector"]
            case .swiftFunc: ["module", "function"]
            case .debugSymbol: ["name"]
            case .javaMethod: ["class_name", "method_name"]
            }
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Key.self)
        guard outer.allKeys.count == 1, let key = outer.allKeys.first, let kind = Kind(rawValue: key.stringValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "an anchor holds exactly one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        let c = try outer.nestedContainer(keyedBy: Key.self, forKey: key)
        guard Set(c.allKeys.map(\.stringValue)) == kind.fields else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "a \(kind.rawValue) anchor holds exactly \(kind.fields.sorted().joined(separator: ", "))"))
        }
        let string = { (field: String) in try c.decode(String.self, forKey: Key(field)) }
        switch kind {
        case .absolute: self = .absolute(try HexAddress.decode(Key("address"), from: c))
        case .moduleOffset: self = .moduleOffset(name: try string("name"), offset: try ModuleOffset.decode(Key("offset"), from: c))
        case .moduleExport: self = .moduleExport(name: try string("name"), export: try string("export"))
        case .objcMethod: self = .objcMethod(selector: try string("selector"))
        case .swiftFunc: self = .swiftFunc(module: try string("module"), function: try string("function"))
        case .debugSymbol: self = .debugSymbol(name: try string("name"))
        case .javaMethod: self = .javaMethod(className: try string("class_name"), methodName: try string("method_name"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Key.self)
        let (kind, fields) = parts
        var c = outer.nestedContainer(keyedBy: Key.self, forKey: Key(kind.rawValue))
        for (field, value) in fields {
            switch value {
            case .text(let text): try c.encode(text, forKey: Key(field))
            case .offset(let offset): try c.encode(ModuleOffset.number(offset), forKey: Key(field))
            }
        }
    }

    public var toolJSON: JSONObject {
        let (kind, fields) = parts
        var object: JSONObject = ["type": kind.rawValue]
        for (field, value) in fields {
            switch value {
            case .text(let text): object[field] = text
            case .offset(let offset): object[field] = ModuleOffset.number(offset)
            }
        }
        return object
    }

    public init(toolJSON object: JSONObject) throws {
        guard let type = object["type"] as? String, let kind = Kind(rawValue: type) else {
            throw LumaCoreError.invalidArgument("an anchor's type is one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard Set(object.keys).subtracting(["type"]) == kind.fields else {
            throw LumaCoreError.invalidArgument("a \(type) anchor holds type and exactly \(kind.fields.sorted().joined(separator: ", "))")
        }
        let string = { (field: String) in try parseAnchorString(object[field], field: field) }
        let address = { (field: String) in
            guard let value = (object[field] as? String).flatMap(HexAddress.parse) else {
                throw LumaCoreError.invalidArgument("\(field): \(HexAddress.refusal)")
            }
            return value
        }
        switch kind {
        case .absolute: self = .absolute(try address("address"))
        case .moduleOffset:
            guard let offset = ModuleOffset.value(object["offset"]) else { throw LumaCoreError.invalidArgument("offset: \(ModuleOffset.refusal)") }
            self = .moduleOffset(name: try string("name"), offset: offset)
        case .moduleExport: self = .moduleExport(name: try string("name"), export: try string("export"))
        case .objcMethod: self = .objcMethod(selector: try string("selector"))
        case .swiftFunc: self = .swiftFunc(module: try string("module"), function: try string("function"))
        case .debugSymbol: self = .debugSymbol(name: try string("name"))
        case .javaMethod: self = .javaMethod(className: try string("class_name"), methodName: try string("method_name"))
        }
    }

    private enum Part {
        case text(String)
        case offset(UInt64)
    }

    private var parts: (Kind, [(String, Part)]) {
        switch self {
        case .absolute(let address): (.absolute, [("address", .text(HexAddress.string(address)))])
        case .moduleOffset(let name, let offset): (.moduleOffset, [("name", .text(name)), ("offset", .offset(offset))])
        case .moduleExport(let name, let export): (.moduleExport, [("name", .text(name)), ("export", .text(export))])
        case .objcMethod(let selector): (.objcMethod, [("selector", .text(selector))])
        case .swiftFunc(let module, let function): (.swiftFunc, [("module", .text(module)), ("function", .text(function))])
        case .debugSymbol(let name): (.debugSymbol, [("name", .text(name))])
        case .javaMethod(let className, let methodName): (.javaMethod, [("class_name", .text(className)), ("method_name", .text(methodName))])
        }
    }
}

private func moduleBasename(_ name: String) -> String {
    guard let slash = name.lastIndex(of: "/") else { return name }
    return String(name[name.index(after: slash)...])
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
