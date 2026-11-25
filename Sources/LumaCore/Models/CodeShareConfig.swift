import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct CodeShareConfig: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var source: String
    public var exports: [String]

    public var project: CodeShareProjectRef?
    public var lastSyncedHash: String?
    public var lastReviewedHash: String?

    public var fridaVersion: String?

    public var allowRemoteUpdates: Bool

    public init(
        name: String,
        description: String,
        source: String,
        exports: [String],
        project: CodeShareProjectRef? = nil,
        lastSyncedHash: String? = nil,
        lastReviewedHash: String? = nil,
        fridaVersion: String? = nil,
        allowRemoteUpdates: Bool = false
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.exports = exports
        self.project = project
        self.lastSyncedHash = lastSyncedHash
        self.lastReviewedHash = lastReviewedHash
        self.fridaVersion = fridaVersion
        self.allowRemoteUpdates = allowRemoteUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case source
        case exports
        case project
        case lastSyncedHash = "last_synced_hash"
        case lastReviewedHash = "last_reviewed_hash"
        case fridaVersion = "frida_version"
        case allowRemoteUpdates = "allow_remote_updates"
    }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        source = try c.decode(String.self, forKey: .source)
        exports = try c.decode([String].self, forKey: .exports)
        project = try c.decodeIfPresent(CodeShareProjectRef.self, forKey: .project)
        lastSyncedHash = try c.decodeIfPresent(String.self, forKey: .lastSyncedHash)
        lastReviewedHash = try c.decodeIfPresent(String.self, forKey: .lastReviewedHash)
        fridaVersion = try c.decodeIfPresent(String.self, forKey: .fridaVersion)
        allowRemoteUpdates = try c.decode(Bool.self, forKey: .allowRemoteUpdates)
    }

    public static func decode(from data: Data) throws -> CodeShareConfig {
        let decoder = JSONDecoder()
        decoder.userInfo[.refusesUnknownKeys] = true
        return try decoder.decode(CodeShareConfig.self, from: data)
    }

    public var currentSourceHash: String {
        let data = Data(source.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct CodeShareProjectRef: Codable, Equatable, Sendable {
    public let id: String
    public let owner: String
    public let slug: String

    public init(id: String, owner: String, slug: String) {
        self.id = id
        self.owner = owner
        self.slug = slug
    }

    public var url: URL {
        URL(string: "https://codeshare.frida.re/@\(owner)/\(slug)/")!
    }

    public var apiEndpoint: URL {
        URL(string: "https://codeshare.frida.re/api/project/\(owner)/\(slug)")!
    }
}
