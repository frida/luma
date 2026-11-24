import Foundation

public enum InstrumentIcon: Hashable, Sendable {
    case symbolic(String)
    case pixels(Data)
}

extension InstrumentIcon: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case symbolic, pixels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .symbolic:
            self = .symbolic(try c.decode(String.self, forKey: .value))
        case .pixels:
            let b64 = try c.decode(String.self, forKey: .value)
            guard let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "invalid base64")
            }
            self = .pixels(data)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbolic(let id):
            try c.encode(Kind.symbolic, forKey: .kind)
            try c.encode(id, forKey: .value)
        case .pixels(let data):
            try c.encode(Kind.pixels, forKey: .kind)
            try c.encode(data.base64EncodedString(), forKey: .value)
        }
    }
}

extension InstrumentIcon {
    public func toJSON() -> [String: Any] {
        switch self {
        case .symbolic(let id): return ["kind": "symbolic", "value": id]
        case .pixels(let data): return ["kind": "pixels", "value": data.base64EncodedString()]
        }
    }

    public static func fromJSON(_ raw: Any?) -> InstrumentIcon? {
        guard let obj = raw as? [String: Any],
            let kind = obj["kind"] as? String,
            let value = obj["value"] as? String
        else { return nil }
        switch kind {
        case "symbolic": return .symbolic(value)
        case "pixels": return Data(base64Encoded: value).map(InstrumentIcon.pixels)
        default: return nil
        }
    }

    public func encodedJSONString() -> String {
        let data = try! JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodedJSONString(_ s: String) -> InstrumentIcon {
        try! JSONDecoder().decode(InstrumentIcon.self, from: Data(s.utf8))
    }
}

public struct InstrumentIconConcept: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let sfSymbol: String
    public let symbolicIcon: String
}

public enum InstrumentIconCatalog {
    public static let all: [InstrumentIconConcept] = [
        .init(id: "wand-stars",      displayName: "Magic Wand", sfSymbol: "wand.and.stars",                    symbolicIcon: "applications-utilities-symbolic"),
        .init(id: "puzzle",          displayName: "Puzzle",     sfSymbol: "puzzlepiece.extension",             symbolicIcon: "preferences-desktop-apps-symbolic"),
        .init(id: "bug",             displayName: "Bug",        sfSymbol: "ladybug",                           symbolicIcon: "tools-check-spelling-symbolic"),
        .init(id: "magnifyingglass", displayName: "Search",     sfSymbol: "magnifyingglass",                   symbolicIcon: "system-search-symbolic"),
        .init(id: "gauge",           displayName: "Gauge",      sfSymbol: "gauge.with.dots.needle.50percent",  symbolicIcon: "speedometer-symbolic"),
        .init(id: "antenna",         displayName: "Antenna",    sfSymbol: "antenna.radiowaves.left.and.right", symbolicIcon: "network-wireless-symbolic"),
        .init(id: "shield",          displayName: "Shield",     sfSymbol: "shield",                            symbolicIcon: "security-high-symbolic"),
        .init(id: "bolt",            displayName: "Bolt",       sfSymbol: "bolt",                              symbolicIcon: "weather-storm-symbolic"),
        .init(id: "key",             displayName: "Key",        sfSymbol: "key",                               symbolicIcon: "dialog-password-symbolic"),
        .init(id: "lock",            displayName: "Lock",       sfSymbol: "lock",                              symbolicIcon: "system-lock-screen-symbolic"),
        .init(id: "network",         displayName: "Network",    sfSymbol: "network",                           symbolicIcon: "network-workgroup-symbolic"),
        .init(id: "cpu",             displayName: "CPU",        sfSymbol: "cpu",                               symbolicIcon: "computer-symbolic"),
        .init(id: "memory",          displayName: "Memory",     sfSymbol: "memorychip",                        symbolicIcon: "drive-harddisk-symbolic"),
        .init(id: "doc-search",      displayName: "Doc Search", sfSymbol: "doc.text.magnifyingglass",          symbolicIcon: "document-print-preview-symbolic"),
        .init(id: "pin",             displayName: "Pin",        sfSymbol: "pin",                               symbolicIcon: "starred-symbolic"),
        .init(id: "scope",           displayName: "Scope",      sfSymbol: "scope",                             symbolicIcon: "view-fullscreen-symbolic"),
        .init(id: "cloud",           displayName: "Cloud",      sfSymbol: "cloud",                             symbolicIcon: "weather-overcast-symbolic"),
        .init(id: "branch",          displayName: "Branch",     sfSymbol: "arrow.triangle.branch",             symbolicIcon: "view-list-symbolic"),
    ]

    public static let `default`: InstrumentIconConcept = all[0]

    public static func concept(forID id: String) -> InstrumentIconConcept {
        all.first { $0.id == id } ?? `default`
    }
}
