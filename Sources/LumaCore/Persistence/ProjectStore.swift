import Foundation
import GRDB

public final class ProjectStore: Sendable {
    private let dbPool: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace { print($0) }
        }
        dbPool = try DatabasePool(path: path, configuration: config)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "processSession") { t in
                t.primaryKey("id", .text).notNull()
                t.column("kindBlob", .blob).notNull()
                t.column("processInfoBlob", .blob)
                t.column("modulesBlob", .blob)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "instrumentInstance") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text).notNull()
                    .references("processSession", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("sourceIdentifier", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("configJSON", .blob).notNull()
            }

            try db.create(table: "replCell") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text).notNull()
                    .references("processSession", onDelete: .cascade)
                t.column("code", .text).notNull()
                t.column("resultData", .blob)
                t.column("timestamp", .datetime).notNull()
            }

            try db.create(table: "notebookEntry") { t in
                t.primaryKey("id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("jsValueData", .blob)
                t.column("binaryData", .blob)
                t.column("sessionID", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "itraceCapture") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text).notNull()
                    .references("processSession", onDelete: .cascade)
                t.column("traceData", .blob).notNull()
                t.column("metadataJSON", .blob).notNull()
            }

            try db.create(table: "addressInsight") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text).notNull()
                    .references("processSession", onDelete: .cascade)
                t.column("address", .integer).notNull()
                t.column("contentJSON", .blob)
            }

            try db.create(table: "remoteDeviceConfig") { t in
                t.primaryKey("id", .text).notNull()
                t.column("host", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 27042)
            }

            try db.create(table: "projectUIState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("selectedSidebarItem", .text)
                t.column("stateJSON", .blob)
            }

            try db.create(table: "projectPackagesState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("stateJSON", .blob)
            }

            try db.create(table: "installedPackage") { t in
                t.primaryKey("id", .text).notNull()
                t.column("packagesStateID", .text).notNull()
                    .references("projectPackagesState", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
            }

            try db.create(table: "projectCollaborationState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("roomID", .text)
            }
        }

        return migrator
    }
}
