import Foundation

public struct InstrumentCompatibility: Codable, Hashable, Sendable {
    public var platforms: Set<String>?
    public var osIDs: Set<String>?
    public var archs: Set<String>?

    public static let universal = InstrumentCompatibility()

    public init(
        platforms: Set<String>? = nil,
        osIDs: Set<String>? = nil,
        archs: Set<String>? = nil
    ) {
        self.platforms = platforms?.nilIfEmpty
        self.osIDs = osIDs?.nilIfEmpty
        self.archs = archs?.nilIfEmpty
    }

    enum CodingKeys: String, CodingKey {
        case platforms
        case osIDs
        case archs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(platforms?.sorted(), forKey: .platforms)
        try container.encodeIfPresent(osIDs?.sorted(), forKey: .osIDs)
        try container.encodeIfPresent(archs?.sorted(), forKey: .archs)
    }

    public var isUniversal: Bool {
        platforms == nil && osIDs == nil && archs == nil
    }

    public func matches(_ params: SystemParameters) -> Bool {
        incompatibilityReason(for: params) == nil
    }

    public func incompatibilityReason(for params: SystemParameters) -> String? {
        var requirements: [String] = []
        if let platforms, !platforms.contains(params.platform) {
            requirements.append("platform \(formatRequirement(platforms, displayedBy: InstrumentCompatibility.platformDisplayName))")
        }
        if let osIDs, !osIDs.contains(params.osID) {
            requirements.append("OS \(formatRequirement(osIDs, displayedBy: InstrumentCompatibility.osDisplayName))")
        }
        if let archs, !archs.contains(params.arch) {
            requirements.append("architecture \(formatRequirement(archs, displayedBy: InstrumentCompatibility.archDisplayName))")
        }
        guard !requirements.isEmpty else { return nil }
        return "Requires \(requirements.joined(separator: ", ")); this session is \(describeSession(params))"
    }

    private func formatRequirement(_ values: Set<String>, displayedBy display: (String) -> String) -> String {
        values.map(display).sorted().joined(separator: "/")
    }

    private func describeSession(_ params: SystemParameters) -> String {
        "\(InstrumentCompatibility.osDisplayName(params.osID))/\(InstrumentCompatibility.archDisplayName(params.arch))"
    }

    public static func platformDisplayName(_ raw: String) -> String {
        platformDisplayNames[raw] ?? raw
    }

    public static func osDisplayName(_ raw: String) -> String {
        osDisplayNames[raw] ?? raw
    }

    public static func archDisplayName(_ raw: String) -> String {
        archDisplayNames[raw] ?? raw
    }

    private static let platformDisplayNames: [String: String] = [
        "windows": "Windows",
        "darwin": "Darwin",
        "linux": "Linux",
        "freebsd": "FreeBSD",
        "qnx": "QNX",
        "barebone": "Barebone",
    ]

    private static let osDisplayNames: [String: String] = [
        "windows": "Windows",
        "macos": "macOS",
        "linux": "Linux",
        "ios": "iOS",
        "watchos": "watchOS",
        "tvos": "tvOS",
        "visionos": "visionOS",
        "android": "Android",
        "freebsd": "FreeBSD",
        "qnx": "QNX",
    ]

    private static let archDisplayNames: [String: String] = [
        "ia32": "x86",
        "x64": "x86_64",
        "arm": "arm",
        "arm64": "arm64",
        "mips": "MIPS",
    ]
}

public struct SystemParameters: Hashable, Sendable {
    public let platform: String
    public let osID: String
    public let arch: String
    public let access: SystemAccess

    public init(platform: String, osID: String, arch: String, access: SystemAccess) {
        self.platform = platform
        self.osID = osID
        self.arch = arch
        self.access = access
    }

    public init?(raw: [String: Any]) {
        guard
            let platform = raw["platform"] as? String,
            let arch = raw["arch"] as? String,
            let os = raw["os"] as? [String: Any],
            let osID = os["id"] as? String,
            let access = (raw["access"] as? String).flatMap(SystemAccess.init(rawValue:))
        else {
            return nil
        }
        self.platform = platform
        self.osID = osID
        self.arch = arch
        self.access = access
    }
}

public enum SystemAccess: String, Hashable, Sendable {
    case full
    case jailed
}

extension Set {
    fileprivate var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
