import Foundation
import GRDB

public struct ProjectPackagesState: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_packages_state"

    public var id: UUID
    public var packageJSON: Data?
    public var packageLockJSON: Data?
    public var packages: [InstalledPackage]

    enum CodingKeys: String, CodingKey {
        case id
        case packageJSON = "package_json"
        case packageLockJSON = "package_lock_json"
    }

    public init(
        id: UUID = UUID(),
        packageJSON: Data? = nil,
        packageLockJSON: Data? = nil,
        packages: [InstalledPackage] = []
    ) {
        self.id = id
        self.packageJSON = packageJSON
        self.packageLockJSON = packageLockJSON
        self.packages = packages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        packageJSON = try container.decodeIfPresent(Data.self, forKey: .packageJSON)
        packageLockJSON = try container.decodeIfPresent(Data.self, forKey: .packageLockJSON)
        packages = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(packageJSON, forKey: .packageJSON)
        try container.encodeIfPresent(packageLockJSON, forKey: .packageLockJSON)
    }
}
