import Foundation
import GRDB

public struct PharoClassDefinition: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pharo_class"

    public var name: String
    public var superclass: String
    public var package: String
    public var tag: String
    public var instanceVariables: String
    public var classVariables: String
    public var classInstanceVariables: String
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case name
        case superclass
        case package
        case tag
        case instanceVariables = "instance_variables"
        case classVariables = "class_variables"
        case classInstanceVariables = "class_instance_variables"
        case updatedAt = "updated_at"
    }

    public init(
        name: String,
        superclass: String,
        package: String,
        tag: String,
        instanceVariables: String,
        classVariables: String,
        classInstanceVariables: String,
        updatedAt: Date = .now
    ) {
        self.name = name
        self.superclass = superclass
        self.package = package
        self.tag = tag
        self.instanceVariables = instanceVariables
        self.classVariables = classVariables
        self.classInstanceVariables = classInstanceVariables
        self.updatedAt = updatedAt
    }
}
