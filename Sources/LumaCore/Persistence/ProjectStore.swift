import Foundation
import GRDB

public final class ProjectStore: Sendable {
    private let dbPool: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbPool = try DatabasePool(path: path, configuration: config)
        try migrator.migrate(dbPool)
    }

    // MARK: - Process Sessions

    public func fetchSessions() throws -> [ProcessSession] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM processSession ORDER BY createdAt DESC").map { self.decodeSession($0) }
        }
    }

    public func fetchSession(id: UUID) throws -> ProcessSession? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM processSession WHERE id = ?", arguments: [id.uuidString]).map { self.decodeSession($0) }
        }
    }

    public func save(_ session: ProcessSession) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO processSession
                    (id, kindBlob, deviceID, deviceName, processName, iconPNGData, phase, detachReason, lastError,
                     createdAt, lastKnownPID, lastAttachedAt, processInfoBlob, modulesBlob)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    session.id.uuidString,
                    try JSONEncoder().encode(session.kind),
                    session.deviceID,
                    session.deviceName,
                    session.processName,
                    session.iconPNGData,
                    session.phase.rawValue,
                    session.detachReason.rawValue,
                    session.lastError,
                    session.createdAt,
                    Int64(session.lastKnownPID),
                    session.lastAttachedAt,
                    session.processInfo.flatMap { try? JSONEncoder().encode($0) },
                    session.lastKnownModules.flatMap { try? JSONEncoder().encode($0) },
                ])
        }
    }

    public func deleteSession(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM processSession WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private func decodeSession(_ row: Row) -> ProcessSession {
        var s = ProcessSession(
            id: UUID(uuidString: row["id"])!,
            kind: try! JSONDecoder().decode(ProcessSession.Kind.self, from: row["kindBlob"]),
            deviceID: row["deviceID"],
            deviceName: row["deviceName"],
            processName: row["processName"],
            lastKnownPID: UInt(row["lastKnownPID"] as Int64)
        )
        s.iconPNGData = row["iconPNGData"]
        s.phase = ProcessSession.Phase(rawValue: row["phase"])!
        s.detachReason = .applicationRequested
        s.lastError = row["lastError"]
        s.createdAt = row["createdAt"]
        s.lastAttachedAt = row["lastAttachedAt"]
        if let blob: Data = row["processInfoBlob"] {
            s.processInfo = try? JSONDecoder().decode(ProcessSession.ProcessInfo.self, from: blob)
        }
        if let blob: Data = row["modulesBlob"] {
            s.lastKnownModules = try? JSONDecoder().decode([ProcessSession.PersistedModule].self, from: blob)
        }
        return s
    }

    // MARK: - Instruments

    public func fetchInstruments(sessionID: UUID) throws -> [InstrumentInstance] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM instrumentInstance WHERE sessionID = ?", arguments: [sessionID.uuidString]).map {
                InstrumentInstance(
                    id: UUID(uuidString: $0["id"])!,
                    sessionID: UUID(uuidString: $0["sessionID"])!,
                    kind: InstrumentKind(rawValue: $0["kind"])!,
                    sourceIdentifier: $0["sourceIdentifier"],
                    isEnabled: $0["isEnabled"],
                    configJSON: $0["configJSON"]
                )
            }
        }
    }

    public func save(_ instance: InstrumentInstance) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO instrumentInstance
                    (id, sessionID, kind, sourceIdentifier, isEnabled, configJSON)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    instance.id.uuidString, instance.sessionID.uuidString,
                    instance.kind.rawValue, instance.sourceIdentifier,
                    instance.isEnabled, instance.configJSON,
                ])
        }
    }

    public func deleteInstrument(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM instrumentInstance WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - REPL Cells

    public func fetchREPLCells(sessionID: UUID) throws -> [REPLCell] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM replCell WHERE sessionID = ? ORDER BY timestamp ASC",
                arguments: [sessionID.uuidString]
            ).map {
                REPLCell(
                    id: UUID(uuidString: $0["id"])!,
                    sessionID: UUID(uuidString: $0["sessionID"])!,
                    code: $0["code"],
                    result: try JSONDecoder().decode(REPLCell.Result.self, from: $0["resultData"]),
                    timestamp: $0["timestamp"],
                    isSessionBoundary: $0["isSessionBoundary"]
                )
            }
        }
    }

    public func save(_ cell: REPLCell) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO replCell
                    (id, sessionID, code, resultData, timestamp, isSessionBoundary)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    cell.id.uuidString, cell.sessionID.uuidString,
                    cell.code, try JSONEncoder().encode(cell.result),
                    cell.timestamp, cell.isSessionBoundary,
                ])
        }
    }

    // MARK: - Notebook

    public func fetchNotebookEntries() throws -> [NotebookEntry] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notebookEntry ORDER BY timestamp ASC").map { self.decodeNotebookEntry($0) }
        }
    }

    public func fetchNotebookEntry(id: UUID) throws -> NotebookEntry? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notebookEntry WHERE id = ?", arguments: [id.uuidString]).map { self.decodeNotebookEntry($0) }
        }
    }

    public func save(_ entry: NotebookEntry) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO notebookEntry
                    (id, sessionID, timestamp, title, details, jsValueData, binaryData, processName, isUserNote)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.id.uuidString, entry.sessionID?.uuidString,
                    entry.timestamp, entry.title, entry.details,
                    entry.jsValue.flatMap { try? JSONEncoder().encode($0) },
                    entry.binaryData, entry.processName, entry.isUserNote,
                ])
        }
    }

    public func deleteNotebookEntry(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM notebookEntry WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private func decodeNotebookEntry(_ row: Row) -> NotebookEntry {
        var entry = NotebookEntry(
            id: UUID(uuidString: row["id"])!,
            timestamp: row["timestamp"],
            title: row["title"],
            details: row["details"]
        )
        if let data: Data = row["jsValueData"] {
            entry.jsValue = try? JSONDecoder().decode(JSInspectValue.self, from: data)
        }
        entry.binaryData = row["binaryData"]
        entry.sessionID = (row["sessionID"] as String?).flatMap(UUID.init(uuidString:))
        entry.processName = row["processName"]
        entry.isUserNote = row["isUserNote"]
        return entry
    }

    // MARK: - ITrace Captures

    public func fetchITraceCaptures(sessionID: UUID) throws -> [ITraceCaptureRecord] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM itraceCapture WHERE sessionID = ? ORDER BY capturedAt ASC",
                arguments: [sessionID.uuidString]
            ).map {
                ITraceCaptureRecord(
                    id: UUID(uuidString: $0["id"])!,
                    sessionID: UUID(uuidString: $0["sessionID"])!,
                    hookID: UUID(uuidString: $0["hookID"])!,
                    callIndex: $0["callIndex"],
                    displayName: $0["displayName"],
                    traceData: $0["traceData"],
                    metadataJSON: $0["metadataJSON"],
                    lost: $0["lost"]
                )
            }
        }
    }

    public func save(_ capture: ITraceCaptureRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO itraceCapture
                    (id, sessionID, hookID, callIndex, capturedAt, displayName, traceData, metadataJSON, lost)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    capture.id.uuidString, capture.sessionID.uuidString,
                    capture.hookID.uuidString, capture.callIndex,
                    capture.capturedAt, capture.displayName,
                    capture.traceData, capture.metadataJSON, capture.lost,
                ])
        }
    }

    // MARK: - Address Insights

    public func fetchInsights(sessionID: UUID) throws -> [AddressInsight] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM addressInsight WHERE sessionID = ?",
                arguments: [sessionID.uuidString]
            ).map { self.decodeInsight($0) }
        }
    }

    public func save(_ insight: AddressInsight) throws {
        try dbPool.write { db in
            let anchorData = try JSONEncoder().encode(insight.anchor)
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO addressInsight
                    (id, sessionID, createdAt, title, kind, anchorJSON, byteCount, lastResolvedAddress)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    insight.id.uuidString, insight.sessionID.uuidString,
                    insight.createdAt, insight.title, insight.kind.rawValue,
                    anchorData, insight.byteCount, insight.lastResolvedAddress.map { Int64(bitPattern: $0) },
                ])
        }
    }

    public func deleteInsight(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM addressInsight WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private func decodeInsight(_ row: Row) -> AddressInsight {
        let anchorData: Data = row["anchorJSON"]
        let anchor = (try? JSONDecoder().decode(AddressAnchor.self, from: anchorData)) ?? .absolute(0)
        var insight = AddressInsight(
            id: UUID(uuidString: row["id"])!,
            sessionID: UUID(uuidString: row["sessionID"])!,
            title: row["title"],
            kind: AddressInsight.Kind(rawValue: row["kind"])!,
            anchor: anchor,
            byteCount: row["byteCount"]
        )
        insight.createdAt = row["createdAt"]
        if let raw: Int64 = row["lastResolvedAddress"] {
            insight.lastResolvedAddress = UInt64(bitPattern: raw)
        }
        return insight
    }

    // MARK: - Remote Devices

    public func fetchRemoteDevices() throws -> [RemoteDeviceConfig] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM remoteDeviceConfig").map {
                RemoteDeviceConfig(
                    id: UUID(uuidString: $0["id"])!,
                    address: $0["address"],
                    certificate: $0["certificate"],
                    origin: $0["origin"],
                    token: $0["token"],
                    keepaliveInterval: $0["keepaliveInterval"]
                )
            }
        }
    }

    public func save(_ config: RemoteDeviceConfig) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO remoteDeviceConfig
                    (id, address, certificate, origin, token, keepaliveInterval)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    config.id.uuidString, config.address,
                    config.certificate, config.origin,
                    config.token, config.keepaliveInterval,
                ])
        }
    }

    public func deleteRemoteDevice(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM remoteDeviceConfig WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Packages State

    public func fetchPackagesState() throws -> ProjectPackagesState {
        try dbPool.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM projectPackagesState LIMIT 1") {
                let id = UUID(uuidString: row["id"] as String)!
                let packages = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM installedPackage WHERE packagesStateID = ? ORDER BY addedAt ASC",
                    arguments: [id.uuidString]
                ).map {
                    InstalledPackage(
                        id: UUID(uuidString: $0["id"])!,
                        name: $0["name"],
                        version: $0["version"],
                        globalAlias: $0["globalAlias"],
                        addedAt: $0["addedAt"]
                    )
                }
                return ProjectPackagesState(
                    id: id,
                    packageJSON: row["packageJSON"],
                    packageLockJSON: row["packageLockJSON"],
                    packages: packages
                )
            }
            return ProjectPackagesState()
        }
    }

    public func save(_ state: ProjectPackagesState) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO projectPackagesState (id, packageJSON, packageLockJSON) VALUES (?, ?, ?)",
                arguments: [state.id.uuidString, state.packageJSON, state.packageLockJSON])

            try db.execute(sql: "DELETE FROM installedPackage WHERE packagesStateID = ?", arguments: [state.id.uuidString])
            for pkg in state.packages {
                try db.execute(
                    sql: """
                        INSERT INTO installedPackage (id, packagesStateID, name, version, globalAlias, addedAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        pkg.id.uuidString, state.id.uuidString,
                        pkg.name, pkg.version, pkg.globalAlias, pkg.addedAt,
                    ])
            }
        }
    }

    // MARK: - Collaboration State

    public func fetchCollaborationState() throws -> ProjectCollaborationState {
        try dbPool.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM projectCollaborationState LIMIT 1") {
                return ProjectCollaborationState(
                    id: UUID(uuidString: row["id"] as String)!,
                    roomID: row["roomID"]
                )
            }
            return ProjectCollaborationState()
        }
    }

    public func save(_ state: ProjectCollaborationState) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO projectCollaborationState (id, roomID) VALUES (?, ?)",
                arguments: [state.id.uuidString, state.roomID])
        }
    }

    // MARK: - Target Picker State

    public func fetchTargetPickerState() throws -> TargetPickerState {
        try dbPool.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM targetPickerState LIMIT 1") {
                return TargetPickerState(
                    id: UUID(uuidString: row["id"] as String)!,
                    lastSelectedDeviceID: row["lastSelectedDeviceID"],
                    lastModeRaw: row["lastModeRaw"],
                    lastSpawnSubmodeRaw: row["lastSpawnSubmodeRaw"],
                    lastSpawnApplicationID: row["lastSpawnApplicationID"],
                    lastSpawnProgramPath: row["lastSpawnProgramPath"],
                    lastSelectedProcessName: row["lastSelectedProcessName"]
                )
            }
            return TargetPickerState()
        }
    }

    public func save(_ state: TargetPickerState) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO targetPickerState
                    (id, lastSelectedDeviceID, lastModeRaw, lastSpawnSubmodeRaw,
                     lastSpawnApplicationID, lastSpawnProgramPath, lastSelectedProcessName)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    state.id.uuidString, state.lastSelectedDeviceID, state.lastModeRaw,
                    state.lastSpawnSubmodeRaw, state.lastSpawnApplicationID,
                    state.lastSpawnProgramPath, state.lastSelectedProcessName,
                ])
        }
    }

    // MARK: - Schema

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "processSession") { t in
                t.primaryKey("id", .text).notNull()
                t.column("kindBlob", .blob).notNull()
                t.column("deviceID", .text).notNull()
                t.column("deviceName", .text).notNull()
                t.column("processName", .text).notNull()
                t.column("iconPNGData", .blob)
                t.column("phase", .integer).notNull()
                t.column("detachReason", .integer).notNull()
                t.column("lastError", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("lastKnownPID", .integer).notNull()
                t.column("lastAttachedAt", .datetime)
                t.column("processInfoBlob", .blob)
                t.column("modulesBlob", .blob)
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
                t.column("resultData", .blob).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("isSessionBoundary", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "notebookEntry") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("details", .text).notNull()
                t.column("jsValueData", .blob)
                t.column("binaryData", .blob)
                t.column("processName", .text)
                t.column("isUserNote", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "itraceCapture") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text).notNull()
                    .references("processSession", onDelete: .cascade)
                t.column("hookID", .text).notNull()
                t.column("callIndex", .integer).notNull()
                t.column("capturedAt", .datetime).notNull()
                t.column("displayName", .text).notNull()
                t.column("traceData", .blob).notNull()
                t.column("metadataJSON", .blob).notNull()
                t.column("lost", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "addressInsight") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionID", .text).notNull()
                    .references("processSession", onDelete: .cascade)
                t.column("createdAt", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("kind", .integer).notNull()
                t.column("anchorJSON", .blob).notNull()
                t.column("byteCount", .integer).notNull()
                t.column("lastResolvedAddress", .integer)
            }

            try db.create(table: "remoteDeviceConfig") { t in
                t.primaryKey("id", .text).notNull()
                t.column("address", .text).notNull()
                t.column("certificate", .text)
                t.column("origin", .text)
                t.column("token", .text)
                t.column("keepaliveInterval", .integer)
            }

            try db.create(table: "projectPackagesState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("packageJSON", .blob)
                t.column("packageLockJSON", .blob)
            }

            try db.create(table: "installedPackage") { t in
                t.primaryKey("id", .text).notNull()
                t.column("packagesStateID", .text).notNull()
                    .references("projectPackagesState", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("globalAlias", .text)
                t.column("addedAt", .datetime).notNull()
            }

            try db.create(table: "projectCollaborationState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("roomID", .text)
            }

            try db.create(table: "targetPickerState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("lastSelectedDeviceID", .text)
                t.column("lastModeRaw", .text)
                t.column("lastSpawnSubmodeRaw", .text)
                t.column("lastSpawnApplicationID", .text)
                t.column("lastSpawnProgramPath", .text)
                t.column("lastSelectedProcessName", .text)
            }
        }

        return migrator
    }
}
