import Foundation

public struct InstalledPackage: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var version: String
    public var globalAlias: String?
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        version: String,
        globalAlias: String? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.globalAlias = globalAlias
        self.addedAt = addedAt
    }
}
