import Foundation

public struct ModuleOutline: Sendable {
    public let counts: ModuleSymbolPage.Counts
    public let swiftTypes: SwiftTypesOutline

    public init(counts: ModuleSymbolPage.Counts, swiftTypes: SwiftTypesOutline) {
        self.counts = counts
        self.swiftTypes = swiftTypes
    }

    static func fromJSON(_ obj: [String: Any]) throws -> ModuleOutline {
        ModuleOutline(
            counts: ModuleSymbolPage.Counts.fromJSON(obj["counts"]),
            swiftTypes: try SwiftTypesOutline.fromJSON(obj["swiftTypes"])
        )
    }
}

public enum SwiftTypesOutline: Sendable, Hashable {
    case absent
    case needsBridge
    case available([SwiftTypeSummary])

    public static let bridgePackageName = "frida-swift-bridge"
    static let bridgeVersionSpec = "^4.0.0-preview.1"

    static func fromJSON(_ value: Any?) throws -> SwiftTypesOutline {
        guard let obj = value as? [String: Any], let state = obj["state"] as? String else {
            throw LumaCoreError.protocolViolation("outlineModule: missing Swift types state")
        }
        switch state {
        case "absent":
            return .absent
        case "needsBridge":
            return .needsBridge
        case "available":
            let entries = (obj["types"] as? [[String: Any]]) ?? []
            return .available(try entries.map(SwiftTypeSummary.fromJSON))
        default:
            throw LumaCoreError.protocolViolation("outlineModule: unknown Swift types state '\(state)'")
        }
    }
}

public struct SwiftTypeSummary: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let kind: SwiftTypeKind

    public init(name: String, kind: SwiftTypeKind) {
        self.name = name
        self.kind = kind
    }

    public func displayName(inModule moduleName: String) -> String {
        let qualifier = moduleName + "."
        return name.hasPrefix(qualifier) ? String(name.dropFirst(qualifier.count)) : name
    }

    var json: [String: Any] {
        ["name": name, "kind": kind.rawValue]
    }

    static func fromJSON(_ obj: [String: Any]) throws -> SwiftTypeSummary {
        guard let name = obj["name"] as? String,
            let kindRaw = obj["kind"] as? String,
            let kind = SwiftTypeKind(rawValue: kindRaw)
        else {
            throw LumaCoreError.protocolViolation("Swift type entry: unexpected shape")
        }
        return SwiftTypeSummary(name: name, kind: kind)
    }
}

extension Array where Element == SwiftTypeSummary {
    public func sidebarHighlights(selectedID: String?, limit: Int = SidebarHighlights.defaultLimit) -> [SwiftTypeSummary] {
        Array(prefix(limit)).withSelected(selectedID, from: self, limit: limit)
    }
}

public enum SwiftTypeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`

    public var title: String {
        switch self {
        case .class: return "Class"
        case .struct: return "Struct"
        case .enum: return "Enum"
        case .protocol: return "Protocol"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .class: return "Classes"
        case .struct: return "Structs"
        case .enum: return "Enums"
        case .protocol: return "Protocols"
        }
    }
}

public struct SwiftTypeDescription: Sendable {
    public let summary: SwiftTypeSummary
    public let superclass: String?
    public let conformances: [String]
    public let conformers: [String]
    public let members: [Member]
    public let functions: [Function]

    public var inheritance: [String] {
        (superclass.map { [$0] } ?? []) + conformances
    }

    public struct Member: Sendable, Hashable {
        public let role: Role
        public let name: String
        public let typeName: String?

        public enum Role: String, Sendable, Hashable {
            case field
            case `case`
            case property
            case staticProperty

            public var title: String {
                switch self {
                case .field: return "Field"
                case .case: return "Case"
                case .property: return "Property"
                case .staticProperty: return "Static Property"
                }
            }
        }
    }

    public struct Function: Sendable, Hashable {
        public let name: String
        public let address: UInt64
        public let anchor: AddressAnchor
    }

    static func fromJSON(_ obj: [String: Any]) throws -> SwiftTypeDescription {
        SwiftTypeDescription(
            summary: try SwiftTypeSummary.fromJSON(obj),
            superclass: obj["superclass"] as? String,
            conformances: (obj["conformances"] as? [String]) ?? [],
            conformers: (obj["conformers"] as? [String]) ?? [],
            members: try ((obj["members"] as? [[String: Any]]) ?? []).map(decodeMember),
            functions: try ((obj["functions"] as? [[String: Any]]) ?? []).map(decodeFunction)
        )
    }

    private static func decodeMember(_ obj: [String: Any]) throws -> Member {
        guard let roleRaw = obj["role"] as? String,
            let role = Member.Role(rawValue: roleRaw),
            let name = obj["name"] as? String
        else {
            throw LumaCoreError.protocolViolation("Swift member entry: unexpected shape")
        }
        return Member(role: role, name: name, typeName: obj["typeName"] as? String)
    }

    private static func decodeFunction(_ obj: [String: Any]) throws -> Function {
        guard let name = obj["name"] as? String,
            let address = ModuleSymbolBundle.parseAddress(obj["address"] as? String),
            let anchor = obj["anchor"] as? JSONObject
        else {
            throw LumaCoreError.protocolViolation("Swift function entry: unexpected shape")
        }
        return Function(name: name, address: address, anchor: try AddressAnchor.fromJSON(anchor))
    }
}
