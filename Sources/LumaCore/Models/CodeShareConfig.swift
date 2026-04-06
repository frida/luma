import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct CodeShareConfig: Codable, Equatable {
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

    public var currentSourceHash: String {
        let data = Data(source.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct CodeShareProjectRef: Codable, Equatable {
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
