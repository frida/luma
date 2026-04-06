import Foundation
import GRDB

public struct InstalledPackage: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "installed_package"

    public var id: UUID
    public var packagesStateID: UUID
    public var name: String
    public var version: String
    public var globalAlias: String?
    public var addedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case packagesStateID = "packages_state_id"
        case name
        case version
        case globalAlias = "global_alias"
        case addedAt = "added_at"
    }

    public init(
        id: UUID = UUID(),
        packagesStateID: UUID = UUID(),
        name: String,
        version: String,
        globalAlias: String? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.packagesStateID = packagesStateID
        self.name = name
        self.version = version
        self.globalAlias = globalAlias
        self.addedAt = addedAt
    }
}
