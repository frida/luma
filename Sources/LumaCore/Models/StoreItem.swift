import Foundation

public struct StoreItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: StoreItemKind
    public let publisher: StorePublisher
    public let slug: String
    public let name: String
    public let summary: String
    public let category: StoreCategory.ID
    public let icon: StoreItemIcon
    public let compatibility: InstrumentCompatibility
    public let access: StoreAccess
    public let version: StoreVersion
    public let minAppVersion: StoreVersion?
    public let publishedAt: Date

    var path: String {
        Self.path(of: id)
    }

    static func path(of id: String) -> String {
        "/store/items/\(id)"
    }

    static func fromWireJSON(_ raw: Any?) -> StoreItem? {
        guard let obj = raw as? JSONObject,
            let id = obj["id"] as? String,
            let kind = (obj["kind"] as? String).flatMap(StoreItemKind.init(rawValue:)),
            let publisher = StorePublisher.fromWireJSON(obj["publisher"]),
            let slug = obj["slug"] as? String,
            let name = obj["name"] as? String,
            let summary = obj["summary"] as? String,
            let category = obj["category"] as? String,
            let icon = StoreItemIcon.fromWireJSON(obj["icon"]),
            let access = StoreAccess.fromWireJSON(obj["access"]),
            let version = (obj["version"] as? String).flatMap(StoreVersion.init),
            let publishedAt = StoreTimestamp.date(from: obj["published_at"]),
            isValidName(slug), id == "\(publisher.handle)/\(slug)", isValidName(category)
        else { return nil }
        return StoreItem(
            id: id,
            kind: kind,
            publisher: publisher,
            slug: slug,
            name: name,
            summary: summary,
            category: category,
            icon: icon,
            compatibility: CustomInstrumentDef.parseCompatibility(obj["compatibility"]),
            access: access,
            version: version,
            minAppVersion: (obj["min_app_version"] as? String).flatMap(StoreVersion.init),
            publishedAt: publishedAt
        )
    }

    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,63}/) != nil
    }
}

public enum StoreItemKind: String, Hashable, Sendable {
    case instrument
}

public enum StoreItemIcon: Hashable, Sendable {
    case symbolic(String)
    case pixels

    static func fromWireJSON(_ raw: Any?) -> StoreItemIcon? {
        guard let obj = raw as? JSONObject else { return nil }
        switch obj["kind"] as? String {
        case "symbolic":
            return (obj["value"] as? String).map(StoreItemIcon.symbolic)
        case "pixels":
            return .pixels
        default:
            return nil
        }
    }
}

public struct StorePublisher: Hashable, Sendable {
    public let handle: String
    public let name: String

    static func fromWireJSON(_ raw: Any?) -> StorePublisher? {
        guard let obj = raw as? JSONObject,
            let handle = obj["handle"] as? String,
            let name = obj["name"] as? String,
            StoreItem.isValidName(handle)
        else { return nil }
        return StorePublisher(handle: handle, name: name)
    }
}

public enum StoreAccess: Hashable, Sendable {
    case free
    case sponsor(minimumMonthlyCents: Int)

    func toWireJSON() -> JSONObject {
        switch self {
        case .free:
            return ["kind": "free"]
        case .sponsor(let minimumMonthlyCents):
            return ["kind": "sponsor", "min_monthly_cents": minimumMonthlyCents]
        }
    }

    static func fromWireJSON(_ raw: Any?) -> StoreAccess? {
        guard let obj = raw as? JSONObject else { return nil }
        switch obj["kind"] as? String {
        case "free":
            return .free
        case "sponsor":
            return (obj["min_monthly_cents"] as? Int).map { .sponsor(minimumMonthlyCents: $0) }
        default:
            return nil
        }
    }
}

extension StoreAccess: Codable {
    private enum CodingKeys: String, CodingKey { case kind, minMonthlyCents }
    private enum Kind: String, Codable { case free, sponsor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .free:
            self = .free
        case .sponsor:
            self = .sponsor(minimumMonthlyCents: try c.decode(Int.self, forKey: .minMonthlyCents))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .free:
            try c.encode(Kind.free, forKey: .kind)
        case .sponsor(let minimumMonthlyCents):
            try c.encode(Kind.sponsor, forKey: .kind)
            try c.encode(minimumMonthlyCents, forKey: .minMonthlyCents)
        }
    }
}

public struct StoreItemDetail: Sendable {
    public let item: StoreItem
    public let description: String
    public let versions: [StoreItemVersion]

    static func fromWireJSON(_ obj: JSONObject) -> StoreItemDetail? {
        guard let item = StoreItem.fromWireJSON(obj["item"]),
            let description = obj["description"] as? String,
            let versions = obj["versions"] as? [JSONObject]
        else { return nil }
        return StoreItemDetail(item: item, description: description, versions: versions.compactMap(StoreItemVersion.fromWireJSON))
    }
}

public struct StoreItemVersion: Hashable, Sendable {
    public let version: StoreVersion
    public let minAppVersion: StoreVersion?
    public let notes: String
    public let publishedAt: Date

    static func fromWireJSON(_ obj: JSONObject) -> StoreItemVersion? {
        guard let version = (obj["version"] as? String).flatMap(StoreVersion.init),
            let notes = obj["notes"] as? String,
            let publishedAt = StoreTimestamp.date(from: obj["published_at"])
        else { return nil }
        return StoreItemVersion(
            version: version,
            minAppVersion: (obj["min_app_version"] as? String).flatMap(StoreVersion.init),
            notes: notes,
            publishedAt: publishedAt
        )
    }
}

enum StoreTimestamp {
    static func date(from raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return withFractionalSeconds.date(from: text) ?? withoutFractionalSeconds.date(from: text)
    }

    private nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
