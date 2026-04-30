import Foundation
import GRDB

public final class ProjectStore: Sendable {
    public static let didCommitNotification = Notification.Name("LumaCore.ProjectStore.didCommit")

    public let instanceID = UUID()
    private let db: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        db = try DatabaseQueue(path: path, configuration: config)
        try db.write(Self.createSchema)

        let id = instanceID
        let observer = CommitNotifyingObserver(instanceID: id)
        try db.write { db in
            db.add(transactionObserver: observer, extent: .databaseLifetime)
        }
    }

    /// Exports a consistent SQLite snapshot to `destination`, including any
    /// data still sitting in the WAL. Uses SQLite's `VACUUM INTO`, which
    /// produces a fresh, self-contained database file with no sidecar WAL
    /// or -shm files.
    public func exportSnapshot(to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try db.writeWithoutTransaction { db in
            let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
            try db.execute(sql: "VACUUM INTO '\(escaped)'")
        }
    }

    /// Standalone variant for callers that don't have a live `ProjectStore`
    /// open — opens a short-lived connection to `source`, runs the vacuum,
    /// then closes.
    public static func exportSnapshot(from source: URL, to destination: URL) throws {
        let store = try ProjectStore(path: source.path)
        try store.exportSnapshot(to: destination)
    }

    // MARK: - Observation

    public func observeSessions(
        onChange: @escaping @Sendable ([ProcessSession]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try ProcessSession
                        .order(Column("created_at").desc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func observeNotebookEntries(
        onChange: @escaping @Sendable ([NotebookEntry]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try NotebookEntry
                        .order(Column("position").asc, Column("id").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func observeREPLCells(
        sessionID: UUID,
        onChange: @escaping @Sendable ([REPLCell]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try REPLCell
                        .filter(Column("session_id") == sessionID)
                        .order(Column("timestamp").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func observeAllInstruments(
        onChange: @escaping @Sendable ([UUID: [InstrumentInstance]]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try InstrumentInstance.fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }) { rows in
                    onChange(Dictionary(grouping: rows, by: \.sessionID))
                }
        )
    }

    public func observeAllInsights(
        onChange: @escaping @Sendable ([UUID: [AddressInsight]]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try AddressInsight.fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }) { rows in
                    onChange(Dictionary(grouping: rows, by: \.sessionID))
                }
        )
    }

    public func observeAllITraceCaptures(
        onChange: @escaping @Sendable ([UUID: [ITraceCaptureRecord]]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try ITraceCaptureRecord.fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }) { rows in
                    onChange(Dictionary(grouping: rows, by: \.sessionID))
                }
        )
    }

    public func observeInstalledPackages(
        onChange: @escaping @Sendable ([InstalledPackage]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try InstalledPackage
                        .order(Column("added_at").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    // MARK: - Process Sessions

    public func fetchSessions() throws -> [ProcessSession] {
        try db.read { db in
            try ProcessSession
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    public func fetchSession(id: UUID) throws -> ProcessSession? {
        try db.read { db in
            try ProcessSession.fetchOne(db, key: id)
        }
    }

    public func save(_ session: ProcessSession) throws {
        try db.write { db in
            try session.save(db)
        }
    }

    public func deleteSession(id: UUID) throws {
        try db.write { db in
            _ = try ProcessSession.deleteOne(db, key: id)
        }
    }

    // MARK: - Instruments

    public func fetchInstrument(id: UUID) throws -> InstrumentInstance? {
        try db.read { db in
            try InstrumentInstance.fetchOne(db, key: id)
        }
    }

    public func fetchInstruments(sessionID: UUID) throws -> [InstrumentInstance] {
        try db.read { db in
            try InstrumentInstance
                .filter(Column("session_id") == sessionID)
                .fetchAll(db)
        }
    }

    public func save(_ instance: InstrumentInstance) throws {
        try db.write { db in
            try instance.save(db)
        }
    }

    public func deleteInstrument(id: UUID) throws {
        try db.write { db in
            _ = try InstrumentInstance.deleteOne(db, key: id)
        }
    }

    // MARK: - REPL Cells

    public func fetchREPLCells(sessionID: UUID) throws -> [REPLCell] {
        try db.read { db in
            try REPLCell
                .filter(Column("session_id") == sessionID)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    public func fetchREPLCell(id: UUID) throws -> REPLCell? {
        try db.read { db in
            try REPLCell.fetchOne(db, key: id)
        }
    }

    public func save(_ cell: REPLCell) throws {
        try db.write { db in
            try cell.save(db)
        }
    }

    // MARK: - Notebook

    public func fetchNotebookEntries() throws -> [NotebookEntry] {
        try db.read { db in
            try NotebookEntry
                .order(Column("position").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    public func maxNotebookEntryPosition() throws -> Double? {
        try db.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT MAX(position) FROM notebook_entry"
            )
        }
    }

    public func fetchNotebookEntry(id: UUID) throws -> NotebookEntry? {
        try db.read { db in
            try NotebookEntry.fetchOne(db, key: id)
        }
    }

    public func save(_ entry: NotebookEntry) throws {
        try db.write { db in
            try entry.save(db)
        }
    }

    public func deleteNotebookEntry(id: UUID) throws {
        try db.write { db in
            _ = try NotebookEntry.deleteOne(db, key: id)
        }
    }

    // MARK: - Notebook Outbox

    public func saveOutboxOp(_ op: NotebookOp) throws {
        try db.write { db in
            try saveOutboxOp(op, in: db)
        }
    }

    public func saveOutboxOps(_ ops: [NotebookOp]) throws {
        try db.write { db in
            for op in ops {
                try saveOutboxOp(op, in: db)
            }
        }
    }

    public func fetchOutboxOps() throws -> [NotebookOp] {
        try db.read { db in
            let rows = try NotebookOutboxRecord
                .order(Column("created_at").asc, Column("op_id").asc)
                .fetchAll(db)
            return rows.compactMap { $0.toOp() }
        }
    }

    public func removeOutboxOp(opID: UUID) throws {
        try db.write { db in
            _ = try NotebookOutboxRecord.deleteOne(db, key: opID.uuidString)
        }
    }

    public func clearOutbox() throws {
        try db.write { db in
            _ = try NotebookOutboxRecord.deleteAll(db)
        }
    }

    private func saveOutboxOp(_ op: NotebookOp, in db: Database) throws {
        let payload = op.toJSON()
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let binary: Data? = {
            if case let .add(add) = op { return add.entry.binaryData }
            return nil
        }()
        let record = NotebookOutboxRecord(
            opID: op.opID.uuidString,
            kind: op.kind,
            entryID: op.entryID.uuidString,
            payloadJSON: json,
            binaryData: binary,
            createdAt: Date()
        )
        try record.save(db)
    }

    // MARK: - Session Outbox

    public func saveSessionOutboxOp(_ op: SessionOp) throws {
        try db.write { db in
            try saveSessionOutboxOp(op, in: db)
        }
    }

    public func saveSessionOutboxOps(_ ops: [SessionOp]) throws {
        try db.write { db in
            for op in ops {
                try saveSessionOutboxOp(op, in: db)
            }
        }
    }

    public func fetchSessionOutboxOps() throws -> [SessionOp] {
        try db.read { db in
            let rows = try SessionOutboxRecord
                .order(Column("created_at").asc, Column("op_id").asc)
                .fetchAll(db)
            return rows.compactMap { $0.toOp() }
        }
    }

    public func removeSessionOutboxOp(opID: UUID) throws {
        try db.write { db in
            _ = try SessionOutboxRecord.deleteOne(db, key: opID.uuidString)
        }
    }

    public func clearSessionOutbox() throws {
        try db.write { db in
            _ = try SessionOutboxRecord.deleteAll(db)
        }
    }

    private func saveSessionOutboxOp(_ op: SessionOp, in db: Database) throws {
        let payload = op.toJSON()
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let record = SessionOutboxRecord(
            opID: op.opID.uuidString,
            kind: op.kind,
            sessionID: op.sessionID.uuidString,
            payloadJSON: json,
            createdAt: Date()
        )
        try record.save(db)
    }

    // MARK: - ITrace Captures

    public func fetchITraceCaptures(sessionID: UUID) throws -> [ITraceCaptureRecord] {
        try db.read { db in
            try ITraceCaptureRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("captured_at").asc)
                .fetchAll(db)
        }
    }

    public func save(_ capture: ITraceCaptureRecord) throws {
        try db.write { db in
            try capture.save(db)
        }
    }

    public func deleteCapture(id: UUID) throws {
        try db.write { db in
            _ = try ITraceCaptureRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Address Insights

    public func fetchInsights(sessionID: UUID) throws -> [AddressInsight] {
        try db.read { db in
            try AddressInsight
                .filter(Column("session_id") == sessionID)
                .fetchAll(db)
        }
    }

    public func save(_ insight: AddressInsight) throws {
        try db.write { db in
            try insight.save(db)
        }
    }

    public func deleteInsight(id: UUID) throws {
        try db.write { db in
            _ = try AddressInsight.deleteOne(db, key: id)
        }
    }

    // MARK: - Remote Devices

    public func fetchRemoteDevices() throws -> [RemoteDeviceConfig] {
        try db.read { db in
            try RemoteDeviceConfig.fetchAll(db)
        }
    }

    public func save(_ config: RemoteDeviceConfig) throws {
        try db.write { db in
            try config.save(db)
        }
    }

    public func deleteRemoteDevice(id: UUID) throws {
        try db.write { db in
            _ = try RemoteDeviceConfig.deleteOne(db, key: id)
        }
    }

    // MARK: - Packages State

    public func fetchPackagesState() throws -> ProjectPackagesState {
        try db.write { db in
            var state: ProjectPackagesState
            if let existing = try ProjectPackagesState.fetchOne(db) {
                state = existing
            } else {
                state = ProjectPackagesState()
                try state.save(db)
            }
            state.packages = try InstalledPackage
                .filter(Column("packages_state_id") == state.id)
                .order(Column("added_at").asc)
                .fetchAll(db)
            return state
        }
    }

    public func save(_ state: ProjectPackagesState) throws {
        try db.write { db in
            try state.save(db)

            try InstalledPackage
                .filter(Column("packages_state_id") == state.id)
                .deleteAll(db)
            for var pkg in state.packages {
                pkg.packagesStateID = state.id
                try pkg.insert(db)
            }
        }
    }

    // MARK: - Collaboration State

    public func fetchCollaborationState() throws -> ProjectCollaborationState {
        try db.read { db in
            try ProjectCollaborationState.fetchOne(db) ?? ProjectCollaborationState()
        }
    }

    public func save(_ state: ProjectCollaborationState) throws {
        try db.write { db in
            try state.save(db)
        }
    }

    // MARK: - Target Picker State

    public func fetchTargetPickerState() throws -> TargetPickerState {
        try db.read { db in
            try TargetPickerState.fetchOne(db) ?? TargetPickerState()
        }
    }

    public func save(_ state: TargetPickerState) throws {
        try db.write { db in
            try state.save(db)
        }
    }

    // MARK: - Schema

    private static func createSchema(_ db: Database) throws {
        try db.create(table: "process_session", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("kind", .blob).notNull()
            t.column("host", .blob)
            t.column("device_id", .text).notNull()
            t.column("device_name", .text).notNull()
            t.column("process_name", .text).notNull()
            t.column("icon_png_data", .blob)
            t.column("phase", .integer).notNull()
            t.column("detach_reason", .integer).notNull()
            t.column("last_error", .text)
            t.column("created_at", .datetime).notNull()
            t.column("last_known_pid", .integer).notNull()
            t.column("last_attached_at", .datetime)
            t.column("process_info", .blob)
            t.column("last_known_modules", .blob)
        }

        try db.create(table: "instrument_instance", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("source_identifier", .text).notNull()
            t.column("state", .text).notNull().defaults(to: "enabled")
            t.column("config_json", .blob).notNull()
        }

        try db.create(table: "repl_cell", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("code", .text).notNull()
            t.column("result", .blob).notNull()
            t.column("timestamp", .datetime).notNull()
            t.column("is_session_boundary", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "notebook_entry", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("editors", .blob).notNull()
            t.column("timestamp", .datetime).notNull()
            t.column("position", .double).notNull().defaults(to: 0)
            t.column("title", .text).notNull()
            t.column("details", .text).notNull()
            t.column("js_value", .blob)
            t.column("binary_data", .blob)
            t.column("session_id", .text)
            t.column("process_name", .text)
        }

        try db.create(table: "notebook_outbox", ifNotExists: true) { t in
            t.primaryKey("op_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("entry_id", .text).notNull()
            t.column("payload_json", .text).notNull()
            t.column("binary_data", .blob)
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "session_outbox", ifNotExists: true) { t in
            t.primaryKey("op_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("session_id", .text).notNull()
            t.column("payload_json", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "itrace_capture", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("hook_id", .text).notNull()
            t.column("call_index", .integer).notNull()
            t.column("captured_at", .datetime).notNull()
            t.column("display_name", .text).notNull()
            t.column("trace_data", .blob).notNull()
            t.column("metadata_json", .blob).notNull()
            t.column("lost", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "address_insight", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("created_at", .datetime).notNull()
            t.column("title", .text).notNull()
            t.column("kind", .integer).notNull()
            t.column("anchor", .blob).notNull()
            t.column("byte_count", .integer).notNull()
            t.column("last_resolved_address", .integer)
        }

        try db.create(table: "remote_device_config", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("address", .text).notNull()
            t.column("certificate", .text)
            t.column("origin", .text)
            t.column("token", .text)
            t.column("keepalive_interval", .integer)
        }

        try db.create(table: "project_packages_state", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("package_json", .blob)
            t.column("package_lock_json", .blob)
        }

        try db.create(table: "installed_package", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("packages_state_id", .text).notNull()
                .references("project_packages_state", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("version", .text).notNull()
            t.column("global_alias", .text)
            t.column("added_at", .datetime).notNull()
        }

        try db.create(table: "project_collaboration_state", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("lab_id", .text)
        }

        try db.create(table: "target_picker_state", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("last_selected_device_id", .text)
            t.column("last_mode_raw", .text)
            t.column("last_spawn_submode_raw", .text)
            t.column("last_spawn_application_id", .text)
            t.column("last_spawn_program_path", .text)
            t.column("last_selected_process_name", .text)
        }
    }
}

private final class CommitNotifyingObserver: TransactionObserver {
    let instanceID: UUID

    init(instanceID: UUID) {
        self.instanceID = instanceID
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseDidCommit(_ db: Database) {
        let id = instanceID
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: ProjectStore.didCommitNotification,
                object: nil,
                userInfo: ["instanceID": id]
            )
        }
    }
    func databaseDidRollback(_ db: Database) {}
}
