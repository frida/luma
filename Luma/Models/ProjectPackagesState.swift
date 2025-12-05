import Foundation
import Frida
import SwiftData

@Model
final class ProjectPackagesState {
    @Attribute(.unique) var id: UUID = UUID()

    var packageJSON: Data?
    var packageLockJSON: Data?

    @Relationship(deleteRule: .cascade)
    var packages: [InstalledPackage] = []

    init() {}
}

@Model
final class InstalledPackage {
    @Attribute(.unique) var id: UUID
    var name: String
    var version: String
    var globalAlias: String?
    var addedAt: Date

    @Relationship(inverse: \ProjectPackagesState.packages)
    var project: ProjectPackagesState?

    init(name: String, version: String, globalAlias: String? = nil, project: ProjectPackagesState) {
        self.id = UUID()
        self.name = name
        self.version = version
        self.globalAlias = globalAlias
        self.addedAt = Date()
        self.project = project
    }
}
