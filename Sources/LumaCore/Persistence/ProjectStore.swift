import Foundation
import GRDB

public enum ProjectStoreError: Error, LocalizedError {
    case schemaVersionMismatch(expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case .schemaVersionMismatch(let expected, let found):
            return "Project database schema version \(found) does not match expected \(expected). Open with an older build or recreate the project."
        }
    }
}

public final class ProjectStore: Sendable {
    public static let didCommitNotification = Notification.Name("LumaCore.ProjectStore.didCommit")
    public static let currentSchemaVersion: Int = 1

    public let instanceID = UUID()
    private let db: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        db = try DatabaseQueue(path: path, configuration: config)
        try db.write(Self.openSchema)

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

    public func observeAllITraces(
        onChange: @escaping @Sendable ([UUID: [ITrace]]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try ITrace.fetchAll(db)
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

    // MARK: - Session UI State

    public func fetchAllSessionUIStates() throws -> [UUID: SessionUIState] {
        try db.read { db in
            let rows = try SessionUIState.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionID, $0) })
        }
    }

    public func save(_ state: SessionUIState) throws {
        try db.write { db in
            try state.save(db)
        }
    }

    // MARK: - Custom Instrument Def UI State

    public func fetchAllCustomInstrumentDefUIStates() throws -> [UUID: CustomInstrumentDefUIState] {
        try db.read { db in
            let rows = try CustomInstrumentDefUIState.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.defID, $0) })
        }
    }

    public func save(_ state: CustomInstrumentDefUIState) throws {
        try db.write { db in
            try state.save(db)
        }
    }

    // MARK: - ITraces

    public func fetchITraces(sessionID: UUID) throws -> [ITrace] {
        try db.read { db in
            try ITrace
                .filter(Column("session_id") == sessionID)
                .order(Column("started_at").asc)
                .fetchAll(db)
        }
    }

    public func save(_ trace: ITrace) throws {
        try db.write { db in
            try trace.save(db)
        }
    }

    public func deleteITrace(id: UUID) throws {
        try db.write { db in
            _ = try ITrace.deleteOne(db, key: id)
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

    // MARK: - Address notes

    public func fetchAddressNote(id: UUID) throws -> AddressNote? {
        try db.read { db in
            try AddressNote.fetchOne(db, key: id)
        }
    }

    public func fetchAddressNoteMessage(id: UUID) throws -> AddressNoteMessage? {
        try db.read { db in
            try AddressNoteMessage.fetchOne(db, key: id)
        }
    }

    public func fetchAddressNotes(sessionID: UUID) throws -> [AddressNote] {
        try db.read { db in
            try AddressNote
                .filter(Column("session_id") == sessionID)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    public func fetchAddressNoteMessages(noteID: UUID) throws -> [AddressNoteMessage] {
        try db.read { db in
            try AddressNoteMessage
                .filter(Column("note_id") == noteID)
                .order(Column("index"))
                .fetchAll(db)
        }
    }

    public func save(_ note: AddressNote) throws {
        try db.write { db in
            try note.save(db)
        }
    }

    public func save(_ message: AddressNoteMessage) throws {
        try db.write { db in
            try message.save(db)
        }
    }

    public func deleteAddressNote(id: UUID) throws {
        try db.write { db in
            _ = try AddressNote.deleteOne(db, key: id)
        }
    }

    public func saveAddressNoteOutboxOp(_ op: AddressNoteOp) throws {
        try db.write { db in
            let payload = op.toJSON()
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            let json = String(data: data, encoding: .utf8) ?? "{}"
            let record = AddressNoteOutboxRecord(
                opID: op.opID.uuidString,
                kind: op.kind,
                noteID: op.noteID.uuidString,
                payloadJSON: json,
                createdAt: Date()
            )
            try record.save(db)
        }
    }

    public func fetchAddressNoteOutboxOps() throws -> [AddressNoteOp] {
        try db.read { db in
            let rows = try AddressNoteOutboxRecord
                .order(Column("created_at").asc, Column("op_id").asc)
                .fetchAll(db)
            return rows.compactMap { $0.toOp() }
        }
    }

    public func removeAddressNoteOutboxOp(opID: UUID) throws {
        try db.write { db in
            _ = try AddressNoteOutboxRecord.deleteOne(db, key: opID.uuidString)
        }
    }

    public func clearAddressNoteOutbox() throws {
        try db.write { db in
            _ = try AddressNoteOutboxRecord.deleteAll(db)
        }
    }

    // MARK: - Missions

    public func observeMissions(
        onChange: @escaping @Sendable ([Mission]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try Mission
                        .order(Column("created_at").desc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func observeMissionTurns(
        missionID: UUID,
        onChange: @escaping @Sendable ([MissionTurn]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try MissionTurn
                        .filter(Column("mission_id") == missionID)
                        .order(Column("index").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func observeMissionActions(
        missionID: UUID,
        onChange: @escaping @Sendable ([MissionAction]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try MissionAction
                        .filter(Column("mission_id") == missionID)
                        .order(Column("requested_at").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func observeMissionFindings(
        missionID: UUID,
        onChange: @escaping @Sendable ([MissionFinding]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try MissionFinding
                        .filter(Column("mission_id") == missionID)
                        .order(Column("created_at").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func fetchMissions() throws -> [Mission] {
        try db.read { db in
            try Mission.order(Column("created_at").desc).fetchAll(db)
        }
    }

    public func fetchMission(id: UUID) throws -> Mission? {
        try db.read { db in
            try Mission.fetchOne(db, key: id)
        }
    }

    public func save(_ mission: Mission) throws {
        try db.write { db in
            var m = mission
            m.updatedAt = Date()
            try m.save(db)
        }
    }

    @discardableResult
    public func updateMission(id: UUID, _ mutate: (inout Mission) -> Void) -> Mission? {
        try? db.write { db in
            guard var mission = try Mission.fetchOne(db, key: id) else { return nil }
            mutate(&mission)
            mission.updatedAt = Date()
            try mission.save(db)
            return mission
        }
    }

    public func deleteMission(id: UUID) throws {
        try db.write { db in
            _ = try Mission.deleteOne(db, key: id)
        }
    }

    public func fetchMissionTurns(missionID: UUID) throws -> [MissionTurn] {
        try db.read { db in
            try MissionTurn
                .filter(Column("mission_id") == missionID)
                .order(Column("index").asc)
                .fetchAll(db)
        }
    }

    public func save(_ turn: MissionTurn) throws {
        try db.write { db in
            try turn.save(db)
        }
    }

    public func nextMissionTurnIndex(missionID: UUID) throws -> Int {
        try db.read { db in
            let max = try Int.fetchOne(
                db,
                sql: "SELECT MAX(\"index\") FROM mission_turn WHERE mission_id = ?",
                arguments: [missionID.uuidString]
            ) ?? -1
            return max + 1
        }
    }

    public func fetchMissionActions(missionID: UUID) throws -> [MissionAction] {
        try db.read { db in
            try MissionAction
                .filter(Column("mission_id") == missionID)
                .order(Column("requested_at").asc)
                .fetchAll(db)
        }
    }

    public func fetchMissionAction(id: UUID) throws -> MissionAction? {
        try db.read { db in
            try MissionAction.fetchOne(db, key: id)
        }
    }

    public func save(_ action: MissionAction) throws {
        try db.write { db in
            try action.save(db)
        }
    }

    public func fetchMissionFindings(missionID: UUID) throws -> [MissionFinding] {
        try db.read { db in
            try MissionFinding
                .filter(Column("mission_id") == missionID)
                .order(Column("created_at").asc)
                .fetchAll(db)
        }
    }

    public func save(_ finding: MissionFinding) throws {
        try db.write { db in
            try finding.save(db)
        }
    }

    public func deleteMissionFinding(id: UUID) throws {
        try db.write { db in
            _ = try MissionFinding.deleteOne(db, key: id)
        }
    }

    public func fetchMissionEvidence(findingID: UUID) throws -> [MissionEvidence] {
        try db.read { db in
            try MissionEvidence
                .filter(Column("finding_id") == findingID)
                .fetchAll(db)
        }
    }

    public func save(_ evidence: MissionEvidence) throws {
        try db.write { db in
            try evidence.save(db)
        }
    }

    // MARK: - Mission Outbox

    public func saveMissionOutboxOp(_ op: MissionOp) throws {
        try db.write { db in
            try saveMissionOutboxOp(op, in: db)
        }
    }

    public func fetchMissionOutboxOps() throws -> [MissionOp] {
        try db.read { db in
            let rows = try MissionOutboxRecord
                .order(Column("created_at").asc, Column("op_id").asc)
                .fetchAll(db)
            return rows.compactMap { $0.toOp() }
        }
    }

    public func removeMissionOutboxOp(opID: UUID) throws {
        try db.write { db in
            _ = try MissionOutboxRecord.deleteOne(db, key: opID.uuidString)
        }
    }

    public func clearMissionOutbox() throws {
        try db.write { db in
            _ = try MissionOutboxRecord.deleteAll(db)
        }
    }

    private func saveMissionOutboxOp(_ op: MissionOp, in db: Database) throws {
        let payload = op.toJSON()
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let record = MissionOutboxRecord(
            opID: op.opID.uuidString,
            kind: op.kind,
            missionID: op.missionID.uuidString,
            payloadJSON: json,
            createdAt: Date()
        )
        try record.save(db)
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

    // MARK: - Custom Instrument Definitions

    public func observeCustomInstrumentDefs(
        onChange: @escaping @Sendable ([CustomInstrumentDef]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try CustomInstrumentDef
                        .order(Column("created_at").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func fetchCustomInstrumentDefs() throws -> [CustomInstrumentDef] {
        try db.read { db in
            try CustomInstrumentDef
                .order(Column("created_at").asc)
                .fetchAll(db)
        }
    }

    public func fetchCustomInstrumentDef(id: UUID) throws -> CustomInstrumentDef? {
        try db.read { db in
            try CustomInstrumentDef
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)
        }
    }

    public func save(_ def: CustomInstrumentDef) throws {
        try db.write { db in
            try def.save(db)
        }
    }

    public func deleteCustomInstrumentDef(id: UUID) throws {
        try db.write { db in
            _ = try CustomInstrumentDef
                .filter(Column("id") == id.uuidString)
                .deleteAll(db)
        }
    }

    // MARK: - Custom Instrument Files

    public func observeCustomInstrumentFiles(
        onChange: @escaping @Sendable ([UUID: [CustomInstrumentFile]]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try CustomInstrumentFile
                        .order(Column("def_id").asc, Column("path").asc)
                        .fetchAll(db)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }) { files in
                    onChange(Dictionary(grouping: files, by: \.defID))
                }
        )
    }

    public func fetchAllCustomInstrumentFiles() throws -> [CustomInstrumentFile] {
        try db.read { db in
            try CustomInstrumentFile
                .order(Column("def_id").asc, Column("path").asc)
                .fetchAll(db)
        }
    }

    public func fetchCustomInstrumentFiles(defID: UUID) throws -> [CustomInstrumentFile] {
        try db.read { db in
            try CustomInstrumentFile
                .filter(Column("def_id") == defID.uuidString)
                .order(Column("path").asc)
                .fetchAll(db)
        }
    }

    public func fetchCustomInstrumentFile(defID: UUID, path: String) throws -> CustomInstrumentFile? {
        try db.read { db in
            try CustomInstrumentFile
                .filter(Column("def_id") == defID.uuidString && Column("path") == path)
                .fetchOne(db)
        }
    }

    public func save(_ file: CustomInstrumentFile) throws {
        try db.write { db in
            try file.save(db)
        }
    }

    public func deleteCustomInstrumentFile(defID: UUID, path: String) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM custom_instrument_file WHERE def_id = ? AND path = ?",
                arguments: [defID.uuidString, path]
            )
        }
    }

    public func renameCustomInstrumentFile(defID: UUID, from: String, to: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE custom_instrument_file SET path = ? WHERE def_id = ? AND path = ?",
                arguments: [to, defID.uuidString, from]
            )
        }
    }

    public func replaceCustomInstrumentFiles(defID: UUID, files: [CustomInstrumentFile]) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM custom_instrument_file WHERE def_id = ?",
                arguments: [defID.uuidString]
            )
            for file in files {
                try file.save(db)
            }
        }
    }

    // MARK: - Custom Instrument Outbox

    public func saveCustomInstrumentOutboxOp(_ op: CustomInstrumentOp) throws {
        try db.write { db in
            try saveCustomInstrumentOutboxOp(op, in: db)
        }
    }

    public func fetchCustomInstrumentOutboxOps() throws -> [CustomInstrumentOp] {
        try db.read { db in
            let rows = try CustomInstrumentOutboxRecord
                .order(Column("created_at").asc, Column("op_id").asc)
                .fetchAll(db)
            return rows.compactMap { $0.toOp() }
        }
    }

    public func removeCustomInstrumentOutboxOp(opID: UUID) throws {
        try db.write { db in
            _ = try CustomInstrumentOutboxRecord.deleteOne(db, key: opID.uuidString)
        }
    }

    public func clearCustomInstrumentOutbox() throws {
        try db.write { db in
            _ = try CustomInstrumentOutboxRecord.deleteAll(db)
        }
    }

    // MARK: - Widget State

    public func fetchWidgetStates(instanceID: UUID) throws -> [String: WidgetState] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT widget_id, state_json FROM widget_state WHERE instance_id = ?",
                arguments: [instanceID.uuidString]
            )
            var result: [String: WidgetState] = [:]
            for row in rows {
                let widgetID: String = row["widget_id"]
                let json: String = row["state_json"]
                result[widgetID] = try JSONDecoder().decode(WidgetState.self, from: Data(json.utf8))
            }
            return result
        }
    }

    public func saveWidgetState(
        instanceID: UUID,
        widgetID: String,
        sessionID: UUID,
        state: WidgetState
    ) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO widget_state (instance_id, widget_id, session_id, state_json, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(instance_id, widget_id) DO UPDATE SET
                        state_json = excluded.state_json,
                        session_id = excluded.session_id,
                        updated_at = excluded.updated_at
                    """,
                arguments: [instanceID.uuidString, widgetID, sessionID.uuidString, json, Date()]
            )
        }
    }

    public func deleteWidgetState(instanceID: UUID, widgetID: String) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM widget_state WHERE instance_id = ? AND widget_id = ?",
                arguments: [instanceID.uuidString, widgetID]
            )
        }
    }

    public func deleteWidgetStates(instanceID: UUID) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM widget_state WHERE instance_id = ?",
                arguments: [instanceID.uuidString]
            )
        }
    }

    private func saveCustomInstrumentOutboxOp(_ op: CustomInstrumentOp, in db: Database) throws {
        let payload = op.toJSON()
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let record = CustomInstrumentOutboxRecord(
            opID: op.opID.uuidString,
            kind: op.kind,
            defID: op.defID.uuidString,
            payloadJSON: json,
            createdAt: Date()
        )
        try record.save(db)
    }

    // MARK: - Project UI State

    public func fetchProjectUIState() throws -> ProjectUIState {
        try db.read { db in
            try ProjectUIState.fetchOne(db) ?? ProjectUIState()
        }
    }

    public func save(_ state: ProjectUIState) throws {
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

    private static func openSchema(_ db: Database) throws {
        let userTableCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ) ?? 0
        let storedVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0

        if userTableCount == 0 {
            try createSchema(db)
            try db.execute(sql: "PRAGMA user_version = \(currentSchemaVersion)")
            return
        }

        guard storedVersion == currentSchemaVersion else {
            throw ProjectStoreError.schemaVersionMismatch(
                expected: currentSchemaVersion,
                found: storedVersion
            )
        }
        try createSchema(db)
    }

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
            t.column("arming_state", .blob)
            t.column("last_arm_pattern", .text)
            t.column("detach_reason", .integer).notNull()
            t.column("last_error", .text)
            t.column("created_at", .datetime).notNull()
            t.column("last_known_pid", .integer).notNull()
            t.column("last_attached_at", .datetime)
            t.column("process_info", .blob)
            t.column("last_known_main_module", .blob)
            t.column("last_known_modules", .blob)
            t.column("last_known_threads", .blob)
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
            t.column("author", .blob)
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

        try db.create(table: "itrace", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("origin", .blob).notNull()
            t.column("display_name", .text).notNull()
            t.column("started_at", .datetime).notNull()
            t.column("stopped_at", .datetime)
            t.column("metadata_json", .blob).notNull()
            t.column("data_size", .integer).notNull().defaults(to: 0)
            t.column("lost", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "session_ui_state", ifNotExists: true) { t in
            t.primaryKey("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("sidebar_expansion", .text).notNull().defaults(to: SidebarExpansion.expanded.rawValue)
            t.column("detail_section", .text)
            t.column("last_selected_module_id", .text)
            t.column("last_selected_thread_id", .integer)
            t.column("ambient_mission_id", .text)
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

        try db.create(table: "address_note", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("session_id", .text).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("anchor", .blob).notNull()
            t.column("title", .text)
            t.column("editors", .blob).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "address_note_message", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("note_id", .text).notNull()
                .references("address_note", onDelete: .cascade)
            t.column("index", .integer).notNull()
            t.column("role", .text).notNull()
            t.column("author", .blob)
            t.column("body_markdown", .text).notNull()
            t.column("provider_id", .text)
            t.column("model_id", .text)
            t.column("action_id", .text)
            t.column("created_at", .datetime).notNull()
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

        try db.create(table: "custom_instrument_def", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("icon", .text).notNull()
            t.column("compatibility_json", .text).notNull().defaults(to: "{}")
            t.column("entrypoint", .text).notNull()
            t.column("features_json", .text).notNull().defaults(to: "[]")
            t.column("widgets_json", .text).notNull().defaults(to: "[]")
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "custom_instrument_file", ifNotExists: true) { t in
            t.column("def_id", .text).notNull()
                .references("custom_instrument_def", onDelete: .cascade)
            t.column("path", .text).notNull()
            t.column("content", .text).notNull()
            t.primaryKey(["def_id", "path"])
        }

        try db.create(table: "custom_instrument_def_ui_state", ifNotExists: true) { t in
            t.primaryKey("def_id", .text).notNull()
                .references("custom_instrument_def", onDelete: .cascade)
            t.column("sidebar_expansion", .text).notNull().defaults(to: SidebarExpansion.expanded.rawValue)
        }

        try db.create(table: "widget_state", ifNotExists: true) { t in
            t.column("instance_id", .text).notNull()
            t.column("widget_id", .text).notNull()
            t.column("session_id", .text).notNull()
            t.column("state_json", .text).notNull()
            t.column("updated_at", .datetime).notNull()
            t.primaryKey(["instance_id", "widget_id"])
        }

        try db.create(table: "custom_instrument_outbox", ifNotExists: true) { t in
            t.primaryKey("op_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("def_id", .text).notNull()
            t.column("payload_json", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "project_ui_state", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("selected_item_json", .text)
            t.column("event_stream_collapsed", .boolean).notNull().defaults(to: true)
            t.column("event_stream_bottom_height", .double).notNull().defaults(to: 0)
            t.column("collaboration_panel_visible", .boolean).notNull().defaults(to: false)
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

        try db.create(table: "mission", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("editors", .blob).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("title", .text)
            t.column("goal_text", .text).notNull()
            t.column("pending_user_text", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull()
            t.column("provider_id", .text).notNull()
            t.column("model_id", .text).notNull()
            t.column("system_prompt_hash", .text)
            t.column("token_budget_input", .integer).notNull().defaults(to: 0)
            t.column("token_budget_output", .integer).notNull().defaults(to: 0)
            t.column("tokens_used_input", .integer).notNull().defaults(to: 0)
            t.column("tokens_used_output", .integer).notNull().defaults(to: 0)
            t.column("cache_read_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_create_tokens", .integer).notNull().defaults(to: 0)
            t.column("thinking_budget", .integer).notNull().defaults(to: 0)
            t.column("reasoning_effort", .text)
            t.column("temperature", .double)
        }

        try db.create(table: "mission_turn", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("mission_id", .text).notNull()
                .references("mission", onDelete: .cascade)
            t.column("index", .integer).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("role", .text).notNull()
            t.column("content_json", .text).notNull()
            t.column("model_id", .text)
            t.column("stop_reason", .text)
            t.column("input_tokens", .integer).notNull().defaults(to: 0)
            t.column("output_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_read_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_create_tokens", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "mission_action", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("mission_id", .text).notNull()
                .references("mission", onDelete: .cascade)
            t.column("turn_id", .text)
                .references("mission_turn", onDelete: .setNull)
            t.column("tool_name", .text).notNull()
            t.column("args_json", .text).notNull()
            t.column("status", .text).notNull()
            t.column("is_observe", .boolean).notNull().defaults(to: false)
            t.column("session_id", .text)
            t.column("requested_at", .datetime).notNull()
            t.column("decided_at", .datetime)
            t.column("completed_at", .datetime)
            t.column("result_json", .text)
            t.column("result_summary", .text)
            t.column("error", .text)
            t.column("rationale", .text)
            t.column("rejection_reason", .text)
            t.column("tool_call_id", .text)
        }

        try db.create(table: "mission_finding", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("mission_id", .text).notNull()
                .references("mission", onDelete: .cascade)
            t.column("created_at", .datetime).notNull()
            t.column("title", .text).notNull()
            t.column("body_markdown", .text).notNull()
            t.column("confidence", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("status", .text).notNull()
            t.column("session_id", .text)
            t.column("anchor_json", .text)
            t.column("pinned_insight_id", .text)
        }

        try db.create(table: "mission_evidence", ifNotExists: true) { t in
            t.primaryKey("id", .text).notNull()
            t.column("finding_id", .text).notNull()
                .references("mission_finding", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("ref_json", .text).notNull()
            t.column("note", .text)
        }

        try db.create(table: "mission_outbox", ifNotExists: true) { t in
            t.primaryKey("op_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("mission_id", .text).notNull()
            t.column("payload_json", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "address_note_outbox", ifNotExists: true) { t in
            t.primaryKey("op_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("note_id", .text).notNull()
            t.column("payload_json", .text).notNull()
            t.column("created_at", .datetime).notNull()
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
