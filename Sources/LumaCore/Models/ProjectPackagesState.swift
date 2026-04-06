import Foundation

public struct ProjectPackagesState: Codable, Identifiable, Sendable {
    public var id: UUID
    public var packageJSON: Data?
    public var packageLockJSON: Data?
    public var packages: [InstalledPackage]

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
}
