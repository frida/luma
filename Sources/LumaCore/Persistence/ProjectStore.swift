import Foundation
import GRDB
import Synchronization

public enum ProjectStoreError: Error, LocalizedError {
    case madeByEarlierLuma
    case savedByNewerLuma
    case savedByDevelopmentBuild

    public var errorDescription: String? {
        switch self {
        case .madeByEarlierLuma:
            return "This project was made with an earlier version of Luma, which \(LumaVersion.release.map { "Luma \($0.major)" } ?? "this version") cannot open."
        case .savedByNewerLuma:
            return "This project was saved by a newer version of Luma. Update Luma to open it."
        case .savedByDevelopmentBuild:
            return "This project was saved by a development build of Luma whose project format has since changed, so this build cannot open it."
        }
    }
}

public final class ProjectStore: Sendable {
    public static let didEditNotification = Notification.Name("LumaCore.ProjectStore.didEdit")
    public static let didRecordNotification = Notification.Name("LumaCore.ProjectStore.didRecord")
    private static let formatVersion = 7

    public let instanceID = UUID()
    private let db: DatabaseQueue
    private let databasePath: String

    private static let stagedWidgetStates = Mutex<[String: [StagedWidgetState: WidgetState]]>([:])
    private static let pendingAnnouncements = Mutex<Set<Announcement>>([])

    fileprivate struct Announcement: Hashable {
        let kind: Kind
        let instanceID: UUID

        enum Kind {
            case edit
            case record
        }
    }

    private struct StagedWidgetState: Hashable {
        let instanceID: UUID
        let widgetID: String
    }

    public init(path: String) throws {
        databasePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        db = try DatabaseQueue(path: path, configuration: config)
        try Self.prepareSchema(of: db)

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
        writeStagedWidgetStates()
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
            if let stored = try ProcessSession.fetchOne(db, key: session.id) {
                try session.updateChanges(db, from: stored)
            } else {
                try session.insert(db)
            }
        }
    }

    public func deleteSession(id: UUID) throws {
        try db.write { db in
            _ = try ProcessSession.deleteOne(db, key: id)
        }
    }

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

    public func deleteREPLCells(sessionID: UUID) throws {
        try db.write { db in
            _ = try REPLCell
                .filter(Column("session_id") == sessionID)
                .deleteAll(db)
        }
    }

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

    public func saveOutboxOps<Op: OutboxOp>(_ ops: [Op]) throws {
        try db.write { db in
            for op in ops {
                try OutboxRecord(op).save(db)
            }
        }
    }

    public func fetchOutbox() throws -> [QueuedOp] {
        try db.read { db in
            try OutboxRecord
                .order(Column.rowID)
                .fetchAll(db)
                .compactMap { $0.toQueuedOp() }
        }
    }

    public func fetchOutboxOps<Op: OutboxOp>(_ type: Op.Type) throws -> [Op] {
        try db.read { db in
            try OutboxRecord
                .filter(Column("family") == Op.outboxFamily)
                .order(Column.rowID)
                .fetchAll(db)
                .compactMap { $0.toOp(type) }
        }
    }

    public func dropUnreadableOutboxOps() throws -> Int {
        try db.write { db in
            let unreadable = try OutboxRecord.fetchAll(db).filter { $0.toQueuedOp() == nil }
            for record in unreadable {
                try record.delete(db)
            }
            return unreadable.count
        }
    }

    public func fetchOutboxOp(opID: UUID) throws -> QueuedOp? {
        try db.read { db in
            try OutboxRecord.fetchOne(db, key: opID)?.toQueuedOp()
        }
    }

    public func removeOutboxOps(family: String, subject: UUID) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE family = ? AND subject_id = ?", arguments: [family, subject])
        }
    }

    public func withholdFromLab(_ subject: LabSubject) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO lab_withheld_subject (family, subject_id) VALUES (?, ?)",
                arguments: [subject.family.rawValue, subject.id])
        }
    }

    public func releaseToLab(_ subject: LabSubject) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM lab_withheld_subject WHERE family = ? AND subject_id = ?",
                arguments: [subject.family.rawValue, subject.id])
        }
    }

    public func subjectsWithheldFromLab() throws -> Set<LabSubject> {
        try db.read { db in
            Set(
                try Row.fetchAll(db, sql: "SELECT family, subject_id FROM lab_withheld_subject").compactMap { row in
                    LabSubject.Family(rawValue: row["family"]).map { LabSubject($0, row["subject_id"]) }
                })
        }
    }

    @discardableResult
    public func removeOutboxOp(opID: UUID) throws -> Bool {
        try db.write { db in
            try OutboxRecord.deleteOne(db, key: opID)
        }
    }

    public func markKnownToLab(_ subjects: [LabSubject]) throws {
        try db.write { db in
            for subject in subjects {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO lab_known_subject (family, subject_id) VALUES (?, ?)",
                    arguments: [subject.family.rawValue, subject.id]
                )
            }
        }
    }

    public func subjectsKnownToLab(_ family: LabSubject.Family) throws -> Set<UUID> {
        try db.read { db in
            try Set(UUID.fetchAll(db, sql: "SELECT subject_id FROM lab_known_subject WHERE family = ?", arguments: [family.rawValue]))
        }
    }

    public func forgetLabKnowledge() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM lab_known_subject")
            try db.execute(sql: "DELETE FROM lab_dismissed_session")
        }
    }

    public func dismissLabSession(_ sessionID: UUID) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO lab_dismissed_session (session_id) VALUES (?)", arguments: [sessionID])
        }
    }

    public func fetchDismissedLabSessions() throws -> Set<UUID> {
        try db.read { db in
            Set(try UUID.fetchAll(db, sql: "SELECT session_id FROM lab_dismissed_session"))
        }
    }

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

    public func fetchInsights(sessionID: UUID) throws -> [AddressInsight] {
        try db.read { db in
            try AddressInsight
                .filter(Column("session_id") == sessionID)
                .fetchAll(db)
        }
    }

    public func save(_ insight: AddressInsight) throws {
        try db.write { db in
            if let stored = try AddressInsight.fetchOne(db, key: insight.id) {
                try insight.updateChanges(db, from: stored)
            } else {
                try insight.insert(db)
            }
        }
    }

    public func deleteInsight(id: UUID) throws {
        try db.write { db in
            _ = try AddressInsight.deleteOne(db, key: id)
        }
    }

    public func fetchModuleAnalysis(sessionID: UUID, modulePath: String) throws -> ModuleAnalysis? {
        try db.read { db in
            try loadModuleAnalysis(db, sessionID: sessionID, modulePath: modulePath)
        }
    }

    public func fetchModuleMappedRanges(sessionID: UUID, modulePath: String) throws -> [ProcessNode.ModuleRange]? {
        try db.read { db in
            try ModuleAnalysisRow
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_path") == modulePath)
                .fetchOne(db)
                .map { try JSONDecoder().decode([ProcessNode.ModuleRange].self, from: $0.mappedRanges) }
        }
    }

    public func save(_ analysis: ModuleAnalysis) throws {
        try db.write { db in
            try writeModuleAnalysis(db, analysis: analysis)
        }
    }

    public func upsertModuleSymbol(sessionID: UUID, modulePath: String, offset: UInt64, name: String) throws {
        let record = ModuleSymbolRow(
            sessionID: sessionID,
            modulePath: modulePath,
            offset: Int64(bitPattern: offset),
            name: name
        )
        try db.write { db in try record.upsert(db) }
    }

    public func enclosingModuleSymbol(sessionID: UUID, modulePath: String, offset: UInt64) throws -> (offset: UInt64, name: String)? {
        let key = Int64(bitPattern: offset)
        return try db.read { db in
            guard let row = try ModuleSymbolRow
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_path") == modulePath)
                .filter(Column("offset") <= key)
                .order(Column("offset").desc)
                .fetchOne(db)
            else { return nil }
            return (UInt64(bitPattern: row.offset), row.name)
        }
    }

    public func enclosingFunction(sessionID: UUID, modulePath: String, offset: UInt64) throws -> (functionOffset: UInt64, name: String?)? {
        let key = Int64(bitPattern: offset)
        return try db.read { db in
            guard let block = try ModuleAnalysisBlockRow
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_path") == modulePath)
                .filter(Column("offset") <= key)
                .filter(Column("offset") + Column("size") > key)
                .fetchOne(db)
            else { return nil }

            let function = try ModuleAnalysisFunctionRow
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_path") == modulePath)
                .filter(Column("offset") == block.functionOffset)
                .fetchOne(db)

            return (UInt64(bitPattern: block.functionOffset), function?.name)
        }
    }

    private func loadModuleAnalysis(_ db: Database, sessionID: UUID, modulePath: String) throws -> ModuleAnalysis? {
        guard let header = try ModuleAnalysisRow
            .filter(Column("session_id") == sessionID)
            .filter(Column("module_path") == modulePath)
            .fetchOne(db)
        else { return nil }

        let mappedRanges = (try? JSONDecoder().decode([ProcessNode.ModuleRange].self, from: header.mappedRanges)) ?? []

        let functionRows = try ModuleAnalysisFunctionRow
            .filter(Column("session_id") == sessionID)
            .filter(Column("module_path") == modulePath)
            .order(Column("offset"))
            .fetchAll(db)
        let blockRows = try ModuleAnalysisBlockRow
            .filter(Column("session_id") == sessionID)
            .filter(Column("module_path") == modulePath)
            .order(Column("function_offset"), Column("offset"))
            .fetchAll(db)

        var blocksByFunction: [Int64: [ModuleAnalysis.Function.Block]] = [:]
        for row in blockRows {
            blocksByFunction[row.functionOffset, default: []].append(
                .init(offset: UInt64(bitPattern: row.offset), size: UInt64(bitPattern: row.size))
            )
        }

        let functions: [ModuleAnalysis.Function] = functionRows.map { row in
            ModuleAnalysis.Function(
                offset: UInt64(bitPattern: row.offset),
                name: row.name,
                source: ModuleAnalysis.Function.Source(rawValue: row.source) ?? .symbol,
                blocks: blocksByFunction[row.offset] ?? []
            )
        }

        return ModuleAnalysis(
            sessionID: sessionID,
            modulePath: modulePath,
            moduleUUID: header.moduleUUID,
            mappedRanges: mappedRanges,
            functions: functions,
            analyzedAt: header.analyzedAt
        )
    }

    private func writeModuleAnalysis(_ db: Database, analysis: ModuleAnalysis) throws {
        let header = ModuleAnalysisRow(
            sessionID: analysis.sessionID,
            modulePath: analysis.modulePath,
            moduleUUID: analysis.moduleUUID,
            mappedRanges: try JSONEncoder().encode(analysis.mappedRanges),
            analyzedAt: analysis.analyzedAt
        )
        try header.save(db)

        try ModuleAnalysisFunctionRow
            .filter(Column("session_id") == analysis.sessionID)
            .filter(Column("module_path") == analysis.modulePath)
            .deleteAll(db)

        for function in analysis.functions {
            let functionOffset = Int64(bitPattern: function.offset)
            try ModuleAnalysisFunctionRow(
                sessionID: analysis.sessionID,
                modulePath: analysis.modulePath,
                offset: functionOffset,
                name: function.name,
                source: function.source.rawValue
            ).insert(db)

            for block in function.blocks {
                try ModuleAnalysisBlockRow(
                    sessionID: analysis.sessionID,
                    modulePath: analysis.modulePath,
                    functionOffset: functionOffset,
                    offset: Int64(bitPattern: block.offset),
                    size: Int64(bitPattern: block.size)
                ).insert(db)
            }
        }
    }

    public func fetchMemoryPage(sessionID: UUID, moduleUUID: String, offset: UInt64) throws -> MemoryPageModule? {
        try db.read { db in
            try MemoryPageModule
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_uuid") == moduleUUID)
                .filter(Column("offset") == Int64(bitPattern: offset))
                .fetchOne(db)
        }
    }

    public func save(_ page: MemoryPageModule) throws {
        try db.write { db in
            try page.save(db)
        }
    }

    public func fetchMemoryPage(sessionID: UUID, processIdentity: String, address: UInt64) throws -> MemoryPageAnon? {
        try db.read { db in
            try MemoryPageAnon
                .filter(Column("session_id") == sessionID)
                .filter(Column("process_identity") == processIdentity)
                .filter(Column("address") == Int64(bitPattern: address))
                .fetchOne(db)
        }
    }

    public func save(_ page: MemoryPageAnon) throws {
        try db.write { db in
            try page.save(db)
        }
    }

    public func deleteMemoryPage(sessionID: UUID, moduleUUID: String, offset: UInt64) throws {
        try db.write { db in
            _ = try MemoryPageModule
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_uuid") == moduleUUID)
                .filter(Column("offset") == Int64(bitPattern: offset))
                .deleteAll(db)
        }
    }

    public func deleteMemoryPage(sessionID: UUID, processIdentity: String, address: UInt64) throws {
        try db.write { db in
            _ = try MemoryPageAnon
                .filter(Column("session_id") == sessionID)
                .filter(Column("process_identity") == processIdentity)
                .filter(Column("address") == Int64(bitPattern: address))
                .deleteAll(db)
        }
    }

    public func deleteMemoryPagesModule(sessionID: UUID, moduleUUID: String) throws {
        try db.write { db in
            _ = try MemoryPageModule
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_uuid") == moduleUUID)
                .deleteAll(db)
        }
    }

    public func deleteModuleAnalysis(sessionID: UUID, modulePath: String) throws {
        try db.write { db in
            _ = try ModuleAnalysisRow
                .filter(Column("session_id") == sessionID)
                .filter(Column("module_path") == modulePath)
                .deleteAll(db)
        }
    }

    public func deleteMemoryPagesAnon(sessionID: UUID, exceptIdentity: String) throws {
        try db.write { db in
            _ = try MemoryPageAnon
                .filter(Column("session_id") == sessionID)
                .filter(Column("process_identity") != exceptIdentity)
                .deleteAll(db)
        }
    }

    public func fetchObjectChats() throws -> [ObjectChat] {
        try db.read { db in
            try ObjectChat.order(Column("created_at")).fetchAll(db)
        }
    }

    public func fetchObjectChatMessages(chatID: UUID) throws -> [ObjectChatMessage] {
        try db.read { db in
            try ObjectChatMessage
                .filter(Column("chat_id") == chatID)
                .order(Column("index"), Column("created_at"))
                .fetchAll(db)
        }
    }

    public func fetchObjectChatToolCalls(chatID: UUID) throws -> [ObjectChatToolCall] {
        try db.read { db in
            try ObjectChatToolCall
                .filter(Column("chat_id") == chatID)
                .fetchAll(db)
                .sorted(by: ObjectChatToolCall.precedes)
        }
    }

    public func fetchObjectChatObjects(chatID: UUID) throws -> [ObjectChatObject] {
        try db.read { db in
            try ObjectChatObject
                .filter(Column("chat_id") == chatID)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    public func save(_ chat: ObjectChat) throws {
        try db.write { db in
            try chat.save(db)
        }
    }

    public func save(_ message: ObjectChatMessage) throws {
        try db.write { db in
            try message.save(db)
        }
    }

    public func save(_ call: ObjectChatToolCall) throws {
        try db.write { db in
            try call.save(db)
        }
    }

    public func save(_ object: ObjectChatObject) throws {
        try db.write { db in
            try object.save(db)
        }
    }

    public func deleteObjectChat(id: UUID) throws {
        try db.write { db in
            _ = try ObjectChat.deleteOne(db, key: id)
        }
    }

    public func deleteObjectChatMessage(id: UUID) throws {
        try db.write { db in
            _ = try ObjectChatMessage.deleteOne(db, key: id)
        }
    }

    public func rekeyObjectChat(_ chat: ObjectChat, from oldID: UUID) throws {
        try db.write { db in
            try chat.save(db)
            for table in ["object_chat_message", "object_chat_tool_call", "object_chat_object", "object_chat_read_marker"] {
                try db.execute(sql: "UPDATE OR IGNORE \(table) SET chat_id = ? WHERE chat_id = ?", arguments: [chat.id, oldID])
            }
            _ = try ObjectChat.deleteOne(db, key: oldID)
        }
    }

    public func fetchObjectChatReadMarkers() throws -> [UUID: Int] {
        try db.read { db in
            var markers: [UUID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT chat_id, read_through FROM object_chat_read_marker") {
                markers[row["chat_id"]] = row["read_through"]
            }
            return markers
        }
    }

    public func fetchUnsentObjectChatMessages() throws -> [UUID: String] {
        try db.read { db in
            var unsent: [UUID: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT message_id, reason FROM object_chat_unsent") {
                unsent[row["message_id"]] = row["reason"]
            }
            return unsent
        }
    }

    public func saveUnsentObjectChatMessage(_ messageID: UUID, reason: String?) throws {
        try db.write { db in
            if let reason {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO object_chat_unsent (message_id, reason) VALUES (?, ?)", arguments: [messageID, reason])
            } else {
                try db.execute(sql: "DELETE FROM object_chat_unsent WHERE message_id = ?", arguments: [messageID])
            }
        }
    }

    public func saveObjectChatReadMarker(chatID: UUID, readThrough index: Int) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO object_chat_read_marker (chat_id, read_through) VALUES (?, ?)",
                arguments: [chatID, index])
        }
    }

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

    public func fetchAllPendingMissionActions() throws -> [MissionAction] {
        try db.read { db in
            try MissionAction
                .filter(Column("status") == MissionActionStatus.pending.rawValue)
                .order(Column("requested_at").asc)
                .fetchAll(db)
        }
    }

    public func observeAllPendingMissionActions(
        onChange: @escaping @Sendable ([MissionAction]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try MissionAction
                        .filter(Column("status") == MissionActionStatus.pending.rawValue)
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

    public func fetchMissionSteering(missionID: UUID) throws -> [MissionSteer] {
        try db.read { db in
            try MissionSteer
                .filter(Column("mission_id") == missionID)
                .fetchAll(db)
                .sorted(by: MissionSteer.precedes)
        }
    }

    public func save(_ steer: MissionSteer) throws {
        try db.write { db in
            try steer.save(db)
        }
    }

    public func observeMissionSteering(
        missionID: UUID,
        onChange: @escaping @Sendable ([MissionSteer]) -> Void
    ) -> StoreObservation {
        StoreObservation(
            ValueObservation
                .tracking { db in
                    try MissionSteer
                        .filter(Column("mission_id") == missionID)
                        .fetchAll(db)
                        .sorted(by: MissionSteer.precedes)
                }
                .start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
        )
    }

    public func deleteMissionSteering(ids: [UUID]) throws {
        try db.write { db in
            _ = try MissionSteer.deleteAll(db, keys: ids)
        }
    }

    public func deleteMissionRows(turns: [UUID], actions: [UUID], findings: [UUID], evidence: [UUID]) throws {
        try db.write { db in
            _ = try MissionEvidence.deleteAll(db, keys: evidence)
            _ = try MissionFinding.deleteAll(db, keys: findings)
            _ = try MissionAction.deleteAll(db, keys: actions)
            _ = try MissionTurn.deleteAll(db, keys: turns)
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
                arguments: [missionID]
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

    public func countMissionActions(missionID: UUID) throws -> Int {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mission_action WHERE mission_id = ?",
                arguments: [missionID]
            ) ?? 0
        }
    }

    public func hasPendingMissionActions(missionID: UUID) throws -> Bool {
        try db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM mission_action WHERE mission_id = ? AND status = ? LIMIT 1",
                arguments: [missionID, MissionActionStatus.pending.rawValue]
            )
            return count != nil
        }
    }

    public func fetchPendingMissionActions(missionID: UUID) throws -> [MissionAction] {
        try db.read { db in
            try MissionAction
                .filter(Column("mission_id") == missionID && Column("status") == MissionActionStatus.pending.rawValue)
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

    public func fetchVirtualMachines() throws -> [VirtualMachineRecord] {
        try db.read { db in
            try VirtualMachineRecord.fetchAll(db)
        }
    }

    public func save(_ machine: VirtualMachineRecord) throws {
        try db.write { db in
            try machine.save(db)
        }
    }

    public func deleteVirtualMachine(id: UUID) throws {
        try db.write { db in
            _ = try VirtualMachineRecord.deleteOne(db, key: id)
        }
    }

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

    public func fetchLabMembership(labID: String) throws -> LabMembership? {
        try db.read { db in
            try LabMembership.fetchOne(db, key: labID)
        }
    }

    public func save(_ membership: LabMembership) throws {
        try db.write { db in
            try membership.save(db)
        }
    }

    public func deleteLabMemberships() throws {
        try db.write { db in
            _ = try LabMembership.deleteAll(db)
        }
    }

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
                .filter(key: id)
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
                .filter(key: id)
                .deleteAll(db)
        }
    }

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

    public func fetchPatternSources() throws -> [PatternSourceRecord] {
        try db.read { db in
            try PatternSourceRecord
                .order(Column("name").collating(.localizedCaseInsensitiveCompare).asc)
                .fetchAll(db)
        }
    }

    public func fetchPatternSource(id: UUID) throws -> PatternSourceRecord? {
        try db.read { db in
            try PatternSourceRecord.fetchOne(db, key: id)
        }
    }

    public func save(_ record: PatternSourceRecord) throws {
        try db.write { db in
            try record.save(db)
        }
    }

    public func deletePatternSource(id: UUID) throws {
        try db.write { db in
            _ = try PatternSourceRecord.deleteOne(db, key: id)
        }
    }

    public func fetchRecentPlacements() throws -> [PatternPlacementHistory.Entry] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT source_id, type_name FROM recent_placement ORDER BY position")
                .map { PatternPlacementHistory.Entry(sourceID: $0["source_id"], typeName: $0["type_name"]) }
        }
    }

    public func saveRecentPlacements(_ entries: [PatternPlacementHistory.Entry]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM recent_placement")
            for (position, entry) in entries.enumerated() {
                try db.execute(
                    sql: "INSERT INTO recent_placement (position, source_id, type_name) VALUES (?, ?, ?)",
                    arguments: [position, entry.sourceID, entry.typeName])
            }
        }
    }

    public func replacePatternSources(with records: [PatternSourceRecord]) throws {
        try db.write { db in
            _ = try PatternSourceRecord.deleteAll(db)
            for record in records {
                try record.save(db)
            }
        }
    }

    public func fetchPharoClassDefinitions() throws -> [PharoClassDefinition] {
        try db.read { db in
            try PharoClassDefinition.order(Column("updated_at").asc).fetchAll(db)
        }
    }

    public func fetchPharoMethodDefinitions() throws -> [PharoMethodDefinition] {
        try db.read { db in
            try PharoMethodDefinition.order(Column("updated_at").asc).fetchAll(db)
        }
    }

    public func save(_ definition: PharoClassDefinition) throws {
        try db.write { db in
            try definition.save(db)
        }
    }

    public func save(_ definition: PharoMethodDefinition) throws {
        try db.write { db in
            try definition.save(db)
        }
    }

    public func deletePharoClassDefinition(named name: String) throws {
        try db.write { db in
            _ = try PharoClassDefinition.deleteOne(db, key: name)
            _ = try PharoMethodDefinition.filter(Column("class_name") == name).deleteAll(db)
        }
    }

    public func deletePharoMethodDefinition(className: String, side: String, selector: String) throws {
        try db.write { db in
            _ = try PharoMethodDefinition
                .filter(Column("class_name") == className && Column("side") == side && Column("selector") == selector)
                .deleteAll(db)
        }
    }

    public func fetchCustomInstrumentFiles(defID: UUID) throws -> [CustomInstrumentFile] {
        try db.read { db in
            try CustomInstrumentFile
                .filter(Column("def_id") == defID)
                .order(Column("path").asc)
                .fetchAll(db)
        }
    }

    public func fetchCustomInstrumentFile(defID: UUID, path: String) throws -> CustomInstrumentFile? {
        try db.read { db in
            try CustomInstrumentFile
                .filter(Column("def_id") == defID && Column("path") == path)
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
                arguments: [defID, path]
            )
        }
    }

    public func renameCustomInstrumentFile(defID: UUID, from: String, to: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE custom_instrument_file SET path = ? WHERE def_id = ? AND path = ?",
                arguments: [to, defID, from]
            )
        }
    }

    public func replaceCustomInstrumentFiles(defID: UUID, files: [CustomInstrumentFile]) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM custom_instrument_file WHERE def_id = ?",
                arguments: [defID]
            )
            for file in files {
                try file.save(db)
            }
        }
    }

    public func fetchWidgetStates(instanceID: UUID) throws -> [String: WidgetState] {
        writeStagedWidgetStates()
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT widget_id, state_json FROM widget_state WHERE instance_id = ?",
                arguments: [instanceID]
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

    public func stageWidgetState(_ state: WidgetState, instanceID: UUID, widgetID: String) {
        Self.stagedWidgetStates.withLock { staged in
            staged[databasePath, default: [:]][StagedWidgetState(instanceID: instanceID, widgetID: widgetID)] = state
        }
    }

    public func announceRecorded() {
        Self.announce(Announcement(kind: .record, instanceID: instanceID))
    }

    fileprivate static func announce(_ announcement: Announcement) {
        guard pendingAnnouncements.withLock({ $0.insert(announcement).inserted }) else { return }
        DispatchQueue.main.async {
            pendingAnnouncements.withLock { _ = $0.remove(announcement) }
            NotificationCenter.default.post(
                name: announcement.kind == .edit ? didEditNotification : didRecordNotification,
                object: nil,
                userInfo: ["instanceID": announcement.instanceID]
            )
        }
    }

    fileprivate static func isRuntime(_ change: DatabaseEventKind) -> Bool {
        switch change {
        case .insert(let table), .delete(let table):
            runtimeTables.contains(table)
        case .update(let table, let columns):
            runtimeTables.contains(table) || runtimeColumns[table].map(columns.isSubset) == true
        }
    }

    private static let runtimeTables: Set<String> = [
        "itrace", "memory_page_module", "memory_page_anon", "module_analysis", "module_analysis_function", "module_analysis_block",
        "module_symbol", "widget_state", "instrument_child", "outbox", "lab_known_subject", "object_chat_unsent", "object_chat_read_marker",
        "project_collaboration_state", "lab_membership", "recent_placement", "session_ui_state", "project_ui_state",
        "custom_instrument_def_ui_state", "target_picker_state",
    ]

    private static let runtimeColumns: [String: Set<String>] = [
        "process_session": [
            "phase", "detach_reason", "last_error", "last_known_pid", "last_attached_at", "process_info", "last_known_main_module",
            "last_known_modules", "last_known_threads", "icon_png_data",
        ],
        "address_insight": ["last_resolved_address"],
    ]

    public func writeStagedWidgetStates() {
        Self.stagedWidgetStates.withLock { staged in
            for (key, state) in staged.removeValue(forKey: databasePath) ?? [:] {
                try? saveWidgetState(instanceID: key.instanceID, widgetID: key.widgetID, state: state)
            }
        }
    }

    public func saveWidgetState(instanceID: UUID, widgetID: String, state: WidgetState) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO widget_state (instance_id, widget_id, state_json)
                    VALUES (?, ?, ?)
                    ON CONFLICT(instance_id, widget_id) DO UPDATE SET state_json = excluded.state_json
                    """,
                arguments: [instanceID, widgetID, json]
            )
        }
    }

    public func fetchCodeOrigin(ofCustomInstrument defID: UUID) throws -> HostCodeOrigin? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT origin_json FROM custom_instrument_code_origin WHERE def_id = ?", arguments: [defID])
                .flatMap(HostCodeOrigin.init(storedJSON:))
        }
    }

    public func saveCodeOrigin(_ origin: HostCodeOrigin, ofCustomInstrument defID: UUID) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO custom_instrument_code_origin (def_id, origin_json) VALUES (?, ?)
                    ON CONFLICT(def_id) DO UPDATE SET origin_json = excluded.origin_json
                    """,
                arguments: [defID, origin.storedJSON])
        }
    }

    public func fetchInstrumentChildren(instanceID: UUID) throws -> [InstrumentChild] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT template, child_id, position, title, subtitle, badge_json FROM instrument_child WHERE instance_id = ? ORDER BY position",
                arguments: [instanceID]
            ).map { row in
                let badgeJSON: String? = row["badge_json"]
                return InstrumentChild(
                    ref: ChildRef(template: row["template"], id: row["child_id"]), position: row["position"], title: row["title"],
                    subtitle: row["subtitle"], badge: try badgeJSON.map { try JSONDecoder().decode(ChildBadge.self, from: Data($0.utf8)) })
            }
        }
    }

    public func saveInstrumentChild(_ child: InstrumentChild, instanceID: UUID) throws {
        let badgeJSON = child.badge.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) }
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instrument_child (instance_id, template, child_id, position, title, subtitle, badge_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(instance_id, template, child_id) DO UPDATE SET
                        position = excluded.position, title = excluded.title, subtitle = excluded.subtitle, badge_json = excluded.badge_json
                    """,
                arguments: [instanceID, child.ref.template, child.ref.id, child.position, child.title, child.subtitle, badgeJSON]
            )
        }
    }

    public func deleteInstrumentChild(_ ref: ChildRef, instanceID: UUID) throws {
        writeStagedWidgetStates()
        let prefix = WidgetSlot.prefix(of: ref)
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM instrument_child WHERE instance_id = ? AND template = ? AND child_id = ?",
                arguments: [instanceID, ref.template, ref.id])
            try db.execute(
                sql: "DELETE FROM widget_state WHERE instance_id = ? AND substr(widget_id, 1, length(?)) = ?",
                arguments: [instanceID, prefix, prefix])
        }
    }

    public func fetchWidgetPlacements() throws -> [UUID: [String: [PatternPlacement]]] {
        try db.read { db in
            var result: [UUID: [String: [PatternPlacement]]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT instance_id, widget_id, placements FROM widget_placement") {
                let instanceID: UUID = row["instance_id"]
                let widgetID: String = row["widget_id"]
                result[instanceID, default: [:]][widgetID] = try JSONDecoder().decode([PatternPlacement].self, from: row["placements"])
            }
            return result
        }
    }

    public func saveWidgetPlacements(_ placements: [PatternPlacement], instanceID: UUID, widgetID: String) throws {
        let encoded = try JSONEncoder().encode(placements)
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO widget_placement (instance_id, widget_id, placements)
                    VALUES (?, ?, ?)
                    ON CONFLICT(instance_id, widget_id) DO UPDATE SET placements = excluded.placements
                    """,
                arguments: [instanceID, widgetID, encoded]
            )
        }
    }

    public func replaceWidgetPlacements(_ placements: [UUID: [String: [PatternPlacement]]]) throws {
        try db.write { db in
            for (instanceID, byWidget) in placements {
                try db.execute(sql: "DELETE FROM widget_placement WHERE instance_id = ?", arguments: [instanceID])
                for (widgetID, widgetPlacements) in byWidget {
                    try db.execute(
                        sql: "INSERT INTO widget_placement (instance_id, widget_id, placements) VALUES (?, ?, ?)",
                        arguments: [instanceID, widgetID, try JSONEncoder().encode(widgetPlacements)]
                    )
                }
            }
        }
    }

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

    private enum Format {
        case new
        case current
        case earlier
        case later
    }

    private static func prepareSchema(of db: DatabaseQueue) throws {
        switch try db.read(format) {
        case .new:
            try db.write(createSchema)
        case .current:
            guard try db.read(columnsByTable) == expectedColumnsByTable, try db.read(holdsOnlyCurrentEncodings) else {
                throw ProjectStoreError.savedByDevelopmentBuild
            }
        case .earlier:
            throw ProjectStoreError.madeByEarlierLuma
        case .later:
            throw ProjectStoreError.savedByNewerLuma
        }
    }

    private static func holdsOnlyCurrentEncodings(_ db: Database) throws -> Bool {
        guard try InstrumentInstance.fetchAll(db).allSatisfy(\.hasCurrentConfig) else { return false }
        do {
            _ = try AddressInsight.fetchAll(db)
            _ = try SessionUIState.fetchAll(db)
            _ = try ObjectChat.fetchAll(db)
            _ = try REPLCell.fetchAll(db)
            _ = try ITrace.fetchAll(db)
            _ = try NotebookEntry.fetchAll(db)
            _ = try ObjectChatObject.fetchAll(db)
            for row in try ModuleAnalysisRow.fetchAll(db) {
                _ = try JSONDecoder().decode([ProcessNode.ModuleRange].self, from: row.mappedRanges)
            }
            return true
        } catch {
            return false
        }
    }

    private static let expectedColumnsByTable: [String: Set<String>] = {
        let fresh = try! DatabaseQueue()
        try! fresh.write(createSchema)
        return try! fresh.read(columnsByTable)
    }()

    private static func columnsByTable(_ db: Database) throws -> [String: Set<String>] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        var columns: [String: Set<String>] = [:]
        for table in tables {
            columns[table] = Set(try db.columns(in: table).map(\.name))
        }
        return columns
    }

    private static func format(of db: Database) throws -> Format {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version")!
        if version == formatVersion {
            return .current
        }
        if version > formatVersion {
            return .later
        }
        let isEmpty = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")! == 0
        return isEmpty ? .new : .earlier
    }

    private static func createSchema(_ db: Database) throws {
        try db.create(table: "process_session") { t in
            t.primaryKey("id", .blob).notNull()
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

        try db.create(table: "instrument_instance") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
                .indexed()
            t.column("kind", .text).notNull()
            t.column("source_identifier", .text).notNull()
            t.column("state", .text).notNull().defaults(to: "enabled")
            t.column("config_json", .blob).notNull()
        }

        try db.create(table: "repl_cell") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
                .indexed()
            t.column("author", .blob)
            t.column("code", .text).notNull()
            t.column("language", .text).notNull().defaults(to: REPLLanguage.javascript.rawValue)
            t.column("result", .blob).notNull()
            t.column("placements", .blob)
            t.column("timestamp", .datetime).notNull()
            t.column("is_session_boundary", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "notebook_entry") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("kind", .text).notNull()
            t.column("editors", .blob).notNull()
            t.column("timestamp", .datetime).notNull()
            t.column("position", .double).notNull().defaults(to: 0)
            t.column("title", .text).notNull()
            t.column("details", .text).notNull()
            t.column("styled_details", .blob)
            t.column("js_value", .blob)
            t.column("pharo_snapshot", .blob)
            t.column("pharo_result_fuel", .blob)
            t.column("binary_data", .blob)
            t.column("binary_meta", .blob)
            t.column("placements", .blob).notNull()
            t.column("session_id", .blob)
            t.column("process_name", .text)
        }

        try db.create(table: "itrace") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
                .indexed()
            t.column("origin", .blob).notNull()
            t.column("display_name", .text).notNull()
            t.column("started_at", .datetime).notNull()
            t.column("stopped_at", .datetime)
            t.column("metadata_json", .blob).notNull()
            t.column("data_size", .integer).notNull().defaults(to: 0)
            t.column("lost", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "session_ui_state") { t in
            t.primaryKey("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("sidebar_expansion", .text).notNull().defaults(to: SidebarExpansion.expanded.rawValue)
            t.column("modules_expansion", .text).notNull().defaults(to: SidebarExpansion.collapsed.rawValue)
            t.column("threads_expansion", .text).notNull().defaults(to: SidebarExpansion.collapsed.rawValue)
            t.column("collapsed_hook_instruments", .text).notNull().defaults(to: "[]")
            t.column("expanded_modules", .text).notNull().defaults(to: "[]")
            t.column("expanded_swift_type_lists", .text).notNull().defaults(to: "[]")
            t.column("last_selected_module_id", .text)
            t.column("last_selected_thread_id", .integer)
            t.column("repl_language", .text).notNull().defaults(to: REPLLanguage.javascript.rawValue)
            t.column("repl_draft", .text)
            t.column("repl_seek_anchor", .text)
        }

        try db.create(table: "address_insight") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
                .indexed()
            t.column("created_at", .datetime).notNull()
            t.column("user_title", .text)
            t.column("kind", .integer).notNull()
            t.column("anchor", .blob).notNull()
            t.column("byte_count", .integer).notNull()
            t.column("placements", .blob)
            t.column("last_resolved_address", .integer)
            t.column("parent_insight_id", .blob)
        }

        try db.create(table: "object_chat") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("title", .text)
            t.column("subject", .blob).notNull()
            t.column("session_id", .blob)
                .references("process_session", onDelete: .cascade)
                .indexed()
            t.column("editors", .blob).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "object_chat_message") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("chat_id", .blob).notNull()
                .references("object_chat", onDelete: .cascade)
                .indexed()
            t.column("index", .integer).notNull()
            t.column("role", .text).notNull()
            t.column("author", .blob)
            t.column("body_markdown", .text).notNull()
            t.column("reply_to", .blob)
            t.column("asks_assistant", .boolean).notNull()
            t.column("provider_id", .text)
            t.column("model_id", .text)
            t.column("error", .text)
            t.column("input_tokens", .integer).notNull()
            t.column("output_tokens", .integer).notNull()
            t.column("cache_read_tokens", .integer).notNull()
            t.column("cache_create_tokens", .integer).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "object_chat_tool_call") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("chat_id", .blob).notNull()
                .references("object_chat", onDelete: .cascade)
                .indexed()
            t.column("message_id", .blob).notNull()
            t.column("reply_to", .blob).notNull()
            t.column("offset", .integer).notNull()
            t.column("index", .integer).notNull()
            t.column("tool_call_id", .text).notNull()
            t.column("tool", .text).notNull()
            t.column("args", .blob).notNull()
            t.column("asked_by", .blob)
            t.column("executor", .blob)
            t.column("status", .text).notNull()
            t.column("summary", .text)
            t.column("result", .text)
            t.column("error", .text)
            t.column("error_position", .integer)
            t.column("object_id", .text)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "object_chat_object") { t in
            t.column("chat_id", .blob).notNull()
                .references("object_chat", onDelete: .cascade)
            t.column("object_id", .text).notNull()
            t.column("name", .text)
            t.column("class_name", .text).notNull()
            t.column("print_string", .text).notNull()
            t.column("snapshot", .blob)
            t.column("produced_by", .blob)
            t.column("stands_for", .text)
            t.column("added_by", .blob)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.primaryKey(["chat_id", "object_id"])
        }

        try db.create(table: "object_chat_unsent") { t in
            t.primaryKey("message_id", .blob).notNull()
                .references("object_chat_message", onDelete: .cascade)
            t.column("reason", .text).notNull()
        }

        try db.create(table: "object_chat_read_marker") { t in
            t.primaryKey("chat_id", .blob).notNull()
                .references("object_chat", onDelete: .cascade)
            t.column("read_through", .integer).notNull()
        }

        try db.create(table: "memory_page_module") { t in
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("module_uuid", .text).notNull()
            t.column("offset", .integer).notNull()
            t.column("bytes", .blob).notNull()
            t.column("captured_at", .datetime).notNull()
            t.primaryKey(["session_id", "module_uuid", "offset"])
        }

        try db.create(table: "memory_page_anon") { t in
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("process_identity", .text).notNull()
            t.column("address", .integer).notNull()
            t.column("bytes", .blob).notNull()
            t.column("captured_at", .datetime).notNull()
            t.primaryKey(["session_id", "process_identity", "address"])
        }

        try db.create(table: "module_analysis") { t in
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("module_path", .text).notNull()
            t.column("module_uuid", .text)
            t.column("mapped_ranges", .blob).notNull()
            t.column("analyzed_at", .datetime).notNull()
            t.primaryKey(["session_id", "module_path"])
        }

        try db.create(table: "module_analysis_function") { t in
            t.column("session_id", .blob).notNull()
            t.column("module_path", .text).notNull()
            t.column("offset", .integer).notNull()
            t.column("name", .text)
            t.column("source", .text).notNull()
            t.primaryKey(["session_id", "module_path", "offset"])
            t.foreignKey(
                ["session_id", "module_path"],
                references: "module_analysis",
                columns: ["session_id", "module_path"],
                onDelete: .cascade
            )
        }

        try db.create(table: "module_analysis_block") { t in
            t.column("session_id", .blob).notNull()
            t.column("module_path", .text).notNull()
            t.column("function_offset", .integer).notNull()
            t.column("offset", .integer).notNull()
            t.column("size", .integer).notNull()
            t.primaryKey(["session_id", "module_path", "function_offset", "offset"])
            t.foreignKey(
                ["session_id", "module_path", "function_offset"],
                references: "module_analysis_function",
                columns: ["session_id", "module_path", "offset"],
                onDelete: .cascade
            )
        }

        try db.create(
            index: "idx_module_analysis_block_lookup",
            on: "module_analysis_block",
            columns: ["session_id", "module_path", "offset"]
        )

        try db.create(table: "module_symbol") { t in
            t.column("session_id", .blob).notNull()
                .references("process_session", onDelete: .cascade)
            t.column("module_path", .text).notNull()
            t.column("offset", .integer).notNull()
            t.column("name", .text).notNull()
            t.primaryKey(["session_id", "module_path", "offset"])
        }

        try db.create(table: "remote_device_config") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("address", .text).notNull()
            t.column("certificate", .text)
            t.column("origin", .text)
            t.column("token", .text)
            t.column("keepalive_interval", .integer)
        }

        try db.create(table: "virtual_machine") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("name", .text).notNull()
            t.column("template_id", .text).notNull()
            t.column("parameters_json", .text).notNull()
            t.column("agent_path", .text)
            t.column("has_ready_snapshot", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "project_packages_state") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("package_json", .blob)
            t.column("package_lock_json", .blob)
        }

        try db.create(table: "installed_package") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("packages_state_id", .blob).notNull()
                .references("project_packages_state", onDelete: .cascade)
                .indexed()
            t.column("name", .text).notNull()
            t.column("version", .text).notNull()
            t.column("global_alias", .text)
            t.column("added_at", .datetime).notNull()
        }

        try db.create(table: "pattern_source") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("name", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("text", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "pharo_class") { t in
            t.primaryKey("name", .text).notNull()
            t.column("superclass", .text).notNull()
            t.column("package", .text).notNull()
            t.column("tag", .text).notNull()
            t.column("instance_variables", .text).notNull()
            t.column("class_variables", .text).notNull()
            t.column("class_instance_variables", .text).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "pharo_method") { t in
            t.column("class_name", .text).notNull()
            t.column("side", .text).notNull()
            t.column("selector", .text).notNull()
            t.column("category", .text).notNull()
            t.column("source", .text).notNull()
            t.column("updated_at", .datetime).notNull()
            t.primaryKey(["class_name", "side", "selector"])
        }

        try db.create(table: "project_collaboration_state") { t in
            t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
            t.column("lab_id", .text)
        }

        try db.create(table: "lab_membership") { t in
            t.primaryKey("lab_id", .text).notNull()
            t.column("user", .text).notNull()
            t.column("role", .text).notNull()
        }

        try db.create(table: "custom_instrument_def") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("name", .text).notNull()
            t.column("icon", .text).notNull()
            t.column("compatibility_json", .text).notNull().defaults(to: "{}")
            t.column("min_app_version", .text)
            t.column("entrypoint", .text).notNull()
            t.column("dependencies_json", .text).notNull().defaults(to: "{}")
            t.column("settings_json", .text).notNull().defaults(to: "[]")
            t.column("widgets_json", .text).notNull().defaults(to: "[]")
            t.column("layout_json", .text)
            t.column("children_json", .text).notNull().defaults(to: "[]")
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "custom_instrument_file") { t in
            t.column("def_id", .blob).notNull()
                .references("custom_instrument_def", onDelete: .cascade)
            t.column("path", .text).notNull()
            t.column("content", .text).notNull()
            t.primaryKey(["def_id", "path"])
        }

        try db.create(table: "custom_instrument_def_ui_state") { t in
            t.primaryKey("def_id", .blob).notNull()
                .references("custom_instrument_def", onDelete: .cascade)
            t.column("sidebar_expansion", .text).notNull().defaults(to: SidebarExpansion.collapsed.rawValue)
        }

        try db.create(table: "widget_state") { t in
            t.column("instance_id", .blob).notNull()
                .references("instrument_instance", onDelete: .cascade)
            t.column("widget_id", .text).notNull()
            t.column("state_json", .text).notNull()
            t.primaryKey(["instance_id", "widget_id"])
        }

        try db.create(table: "custom_instrument_code_origin") { t in
            t.primaryKey("def_id", .blob).notNull()
                .references("custom_instrument_def", onDelete: .cascade)
            t.column("origin_json", .text).notNull()
        }

        try db.create(table: "instrument_child") { t in
            t.column("instance_id", .blob).notNull()
                .references("instrument_instance", onDelete: .cascade)
            t.column("template", .text).notNull()
            t.column("child_id", .text).notNull()
            t.column("position", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("subtitle", .text)
            t.column("badge_json", .text)
            t.primaryKey(["instance_id", "template", "child_id"])
        }

        try db.create(table: "widget_placement") { t in
            t.column("instance_id", .blob).notNull()
                .references("instrument_instance", onDelete: .cascade)
            t.column("widget_id", .text).notNull()
            t.column("placements", .blob).notNull()
            t.primaryKey(["instance_id", "widget_id"])
        }

        try db.create(table: "project_ui_state") { t in
            t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
            t.column("selected_item_json", .text)
            t.column("collapsed_sections", .text).notNull().defaults(to: "[]")
            t.column("expanded_pattern_sources", .text).notNull().defaults(to: "[]")
            t.column("event_stream_collapsed", .boolean).notNull().defaults(to: true)
            t.column("event_stream_bottom_height", .double).notNull().defaults(to: 0)
            t.column("side_panel", .text)
            t.column("pharo_snippets_json", .text)
            t.column("pharo_page_width", .double)
            t.column("pharo_page_maximized", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "target_picker_state") { t in
            t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
            t.column("last_selected_device_id", .text)
            t.column("last_mode_raw", .text)
            t.column("last_spawn_submode_raw", .text)
            t.column("last_spawn_application_id", .text)
            t.column("last_spawn_program_path", .text)
            t.column("last_selected_process_name", .text)
        }

        try db.create(table: "mission") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("editors", .blob).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("title", .text)
            t.column("goal_text", .text).notNull()
            t.column("status", .text).notNull()
            t.column("provider_id", .text).notNull()
            t.column("model_id", .text).notNull()
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

        try db.create(table: "mission_turn") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("mission_id", .blob).notNull()
                .references("mission", onDelete: .cascade)
                .indexed()
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

        try db.create(table: "mission_action") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("mission_id", .blob).notNull()
                .references("mission", onDelete: .cascade)
                .indexed()
            t.column("turn_id", .blob)
                .references("mission_turn", onDelete: .setNull)
                .indexed()
            t.column("tool_name", .text).notNull()
            t.column("args_json", .text).notNull()
            t.column("status", .text).notNull()
            t.column("is_observe", .boolean).notNull().defaults(to: false)
            t.column("session_id", .blob)
            t.column("requested_at", .datetime).notNull()
            t.column("decided_at", .datetime)
            t.column("completed_at", .datetime)
            t.column("result_json", .text)
            t.column("result_summary", .text)
            t.column("result_attachments_json", .text)
            t.column("error", .text)
            t.column("rationale", .text)
            t.column("rejection_reason", .text)
            t.column("tool_call_id", .text)
            t.column("executor", .blob)
        }

        try db.create(table: "mission_steer") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("mission_id", .blob).notNull()
                .references("mission", onDelete: .cascade)
                .indexed()
            t.column("author", .blob)
            t.column("text", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "mission_finding") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("mission_id", .blob).notNull()
                .references("mission", onDelete: .cascade)
                .indexed()
            t.column("created_at", .datetime).notNull()
            t.column("title", .text).notNull()
            t.column("body_markdown", .text).notNull()
            t.column("confidence", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("status", .text).notNull()
            t.column("session_id", .blob)
            t.column("pinned_insight_id", .blob)
        }

        try db.create(table: "mission_evidence") { t in
            t.primaryKey("id", .blob).notNull()
            t.column("finding_id", .blob).notNull()
                .references("mission_finding", onDelete: .cascade)
                .indexed()
            t.column("kind", .text).notNull()
            t.column("ref_json", .text).notNull()
            t.column("note", .text)
        }

        try db.create(table: "outbox") { t in
            t.primaryKey("op_id", .blob).notNull()
            t.column("family", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("subject_id", .blob).notNull()
            t.column("payload_json", .text).notNull()
            t.column("binary_data", .blob)
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "lab_dismissed_session") { t in
            t.primaryKey("session_id", .blob).notNull()
        }

        try db.create(table: "lab_withheld_subject") { t in
            t.column("family", .text).notNull()
            t.column("subject_id", .blob).notNull()
            t.primaryKey(["family", "subject_id"])
        }

        try db.create(table: "lab_known_subject") { t in
            t.column("family", .text).notNull()
            t.column("subject_id", .blob).notNull()
            t.primaryKey(["family", "subject_id"])
        }

        try db.create(table: "recent_placement") { t in
            t.primaryKey("position", .integer).notNull()
            t.column("source_id", .text).notNull()
            t.column("type_name", .text).notNull()
        }

        try db.execute(sql: "PRAGMA user_version = \(formatVersion)")
    }
}

private final class CommitNotifyingObserver: TransactionObserver {
    let instanceID: UUID

    init(instanceID: UUID) {
        self.instanceID = instanceID
    }

    private var edits = false

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        !ProjectStore.isRuntime(eventKind)
    }

    func databaseDidChange(with event: DatabaseEvent) {
        edits = true
    }

    func databaseDidCommit(_ db: Database) {
        ProjectStore.announce(ProjectStore.Announcement(kind: edits ? .edit : .record, instanceID: instanceID))
        edits = false
    }

    func databaseDidRollback(_ db: Database) {
        edits = false
    }
}
