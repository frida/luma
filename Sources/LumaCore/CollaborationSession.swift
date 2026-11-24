import Foundation
import Frida
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable
@MainActor
public final class CollaborationSession {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case joined(labID: String)
        case error(message: String)
    }

    public struct UserInfo: Identifiable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let avatarURL: URL?

        public init(id: String, name: String, avatarURL: URL?) {
            self.id = id
            self.name = name
            self.avatarURL = avatarURL
        }

        public static func fromJSON(_ obj: [String: Any]) -> UserInfo? {
            guard let id = obj["id"] as? String, let name = obj["name"] as? String else { return nil }
            let avatarURL = (obj["avatar"] as? String).flatMap(URL.init(string:))
            return UserInfo(id: id, name: name, avatarURL: avatarURL)
        }
    }

    public struct Member: Identifiable, Hashable, Sendable {
        public enum Role: String, Codable, Sendable { case owner, member }
        public enum Presence: String, Sendable { case online, offline }

        public let user: UserInfo
        public var role: Role
        public var presence: Presence
        public let joinedAt: String
        public var lastSeenAt: String

        public var id: String { user.id }

        public static func fromJSON(_ obj: [String: Any]) -> Member? {
            guard let userObj = obj["user"] as? [String: Any],
                let user = UserInfo.fromJSON(userObj),
                let roleRaw = obj["role"] as? String,
                let role = Role(rawValue: roleRaw),
                let presenceRaw = obj["presence"] as? String,
                let presence = Presence(rawValue: presenceRaw),
                let joinedAt = obj["joined_at"] as? String,
                let lastSeenAt = obj["last_seen_at"] as? String
            else { return nil }
            return Member(user: user, role: role, presence: presence, joinedAt: joinedAt, lastSeenAt: lastSeenAt)
        }
    }

    public struct Session: Identifiable, Sendable {
        public enum Phase: String, Sendable {
            case attaching
            case attached
            case detached
        }

        public let id: UUID
        public let host: UserInfo
        public let deviceID: String
        public let deviceName: String
        public let pid: UInt
        public let processName: String
        public var phase: Phase
        public var armingState: ProcessSession.ArmingState
        public let createdAt: String
        public var lastSeenAt: String
        public var modules: [ProcessModule]
        public var threads: [ProcessThread]
        public var replCells: [REPLCell]
        public var instruments: [InstrumentInstance]
        public var instrumentAgents: [UUID: InstrumentAgentState]
        public var insights: [AddressInsight]
        public var traces: [ITrace]
        public var processInfo: ProcessSession.ProcessInfo?
        public var moduleAnalyses: [ModuleAnalysis]
        public var moduleSymbols: [SessionOp.UpdateModuleSymbols.Entry]

        public init(
            id: UUID,
            host: UserInfo,
            deviceID: String,
            deviceName: String,
            pid: UInt,
            processName: String,
            phase: Phase,
            armingState: ProcessSession.ArmingState = .unarmed,
            createdAt: String,
            lastSeenAt: String,
            modules: [ProcessModule],
            threads: [ProcessThread] = [],
            replCells: [REPLCell] = [],
            instruments: [InstrumentInstance] = [],
            instrumentAgents: [UUID: InstrumentAgentState] = [:],
            insights: [AddressInsight] = [],
            traces: [ITrace] = [],
            processInfo: ProcessSession.ProcessInfo? = nil,
            moduleAnalyses: [ModuleAnalysis] = [],
            moduleSymbols: [SessionOp.UpdateModuleSymbols.Entry] = []
        ) {
            self.id = id
            self.host = host
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.pid = pid
            self.processName = processName
            self.phase = phase
            self.armingState = armingState
            self.createdAt = createdAt
            self.lastSeenAt = lastSeenAt
            self.modules = modules
            self.threads = threads
            self.replCells = replCells
            self.instruments = instruments
            self.instrumentAgents = instrumentAgents
            self.insights = insights
            self.traces = traces
            self.processInfo = processInfo
            self.moduleAnalyses = moduleAnalyses
            self.moduleSymbols = moduleSymbols
        }

        public static func fromJSON(_ obj: [String: Any]) -> Session? {
            guard let idStr = obj["id"] as? String,
                let id = UUID(uuidString: idStr),
                let hostObj = obj["host"] as? [String: Any],
                let host = UserInfo.fromJSON(hostObj),
                let deviceObj = obj["device"] as? [String: Any],
                let deviceID = deviceObj["id"] as? String,
                let deviceName = deviceObj["name"] as? String,
                let processObj = obj["process"] as? [String: Any],
                let processName = processObj["name"] as? String,
                let phaseRaw = obj["phase"] as? String,
                let phase = Phase(rawValue: phaseRaw),
                let createdAt = obj["created_at"] as? String,
                let lastSeenAt = obj["last_seen_at"] as? String
            else { return nil }

            let pid: UInt
            if let v = processObj["pid"] as? Int { pid = UInt(v) }
            else if let v = processObj["pid"] as? UInt { pid = v }
            else if let v = processObj["pid"] as? NSNumber { pid = v.uintValue }
            else { return nil }

            let moduleObjs = (obj["modules"] as? [[String: Any]]) ?? []
            let modules = moduleObjs.compactMap(ProcessModule.fromJSON)

            let threadObjs = (obj["threads"] as? [[String: Any]]) ?? []
            let threads = threadObjs.compactMap(ProcessThread.fromJSON)

            let cellObjs = (obj["repl_cells"] as? [[String: Any]]) ?? []
            let cells = cellObjs.compactMap(REPLCell.fromWireJSON)

            let instrumentObjs = (obj["instruments"] as? [[String: Any]]) ?? []
            let parsedInstruments = instrumentObjs.compactMap(SessionOp.parseWireInstrument)
            let instruments = parsedInstruments.map(\.instance)
            let instrumentAgents = Dictionary(
                parsedInstruments.compactMap { parsed in parsed.agent.map { (parsed.instance.id, $0) } },
                uniquingKeysWith: { _, last in last })

            let insightObjs = (obj["insights"] as? [[String: Any]]) ?? []
            let insights = insightObjs.compactMap(AddressInsight.fromWireJSON)

            let traceObjs = (obj["traces"] as? [[String: Any]]) ?? []
            let traces = traceObjs.compactMap(ITrace.fromWireJSON)

            let processInfo: ProcessSession.ProcessInfo?
            if let infoObj = obj["process_info"] as? [String: Any],
                let platform = infoObj["platform"] as? String,
                let arch = infoObj["arch"] as? String,
                let pointerSize = infoObj["pointer_size"] as? Int,
                let identity = infoObj["identity"] as? String
            {
                processInfo = ProcessSession.ProcessInfo(
                    platform: platform, arch: arch, pointerSize: pointerSize, identity: identity
                )
            } else {
                processInfo = nil
            }

            let analysisObjs = (obj["module_analyses"] as? [[String: Any]]) ?? []
            let moduleAnalyses = analysisObjs.compactMap(ModuleAnalysis.fromWireJSON)

            let symbolObjs = (obj["module_symbols"] as? [[String: Any]]) ?? []
            let moduleSymbols: [SessionOp.UpdateModuleSymbols.Entry] = symbolObjs.compactMap { entry in
                guard let modulePath = entry["module_path"] as? String,
                    let name = entry["name"] as? String
                else { return nil }
                let rawOffset: Int64
                if let n = entry["offset"] as? Int64 { rawOffset = n }
                else if let n = entry["offset"] as? Int { rawOffset = Int64(n) }
                else { return nil }
                return .init(modulePath: modulePath, offset: UInt64(bitPattern: rawOffset), name: name)
            }

            let armingState: ProcessSession.ArmingState
            if let stateObj = obj["arming_state"] as? [String: Any],
                let parsed = decodeArmingState(stateObj) {
                armingState = parsed
            } else {
                armingState = .unarmed
            }

            return Session(
                id: id,
                host: host,
                deviceID: deviceID,
                deviceName: deviceName,
                pid: pid,
                processName: processName,
                phase: phase,
                armingState: armingState,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                modules: modules,
                threads: threads,
                replCells: cells,
                instruments: instruments,
                instrumentAgents: instrumentAgents,
                insights: insights,
                traces: traces,
                processInfo: processInfo,
                moduleAnalyses: moduleAnalyses,
                moduleSymbols: moduleSymbols
            )
        }
    }

    private let connection: PortalConnection
    private let store: ProjectStore

    private(set) public var status: Status = .disconnected
    private(set) public var labID: String?
    private(set) public var labTitle: String?
    private(set) public var labPictureData: Data?
    private(set) public var labPictureContentType: String?
    private(set) public var localUser: UserInfo?
    private var membership: LabMembership?
    private var pendingJoinLabID: String?
    private var replayedOpIDs: Set<UUID> = []
    private var removedMissionIDs: Set<UUID> = []
    private var replayedForSubjectsTheLabLacks: Set<UUID> = []
    private var opsOverridingJoinSnapshot: [UUID: SessionOp] = [:]
    private var pendingCreateOrJoinDispatched: Bool = false
    private(set) public var members: [Member] = []
    private(set) public var vapidPublicKey: String?
    private(set) public var registeredPushPlatforms: Set<String> = []

    public var isOwner: Bool {
        membership?.role == .owner
    }

    public func isSelf(_ userID: String) -> Bool {
        userID == localUser?.id
    }

    private var portalLease: PortalConnection.Lease?

    private let _statusChanges = AsyncEventSource<Status>()
    public var statusChanges: AsyncStream<Status> { _statusChanges.makeStream() }

    public var onNotebookSnapshot: (([NotebookEntry]) -> Void)?
    public var onEntryUpserted: ((NotebookEntry) -> Void)?
    public var onEntryRemoved: ((UUID) -> Void)?
    public var onEntryRepositioned: ((UUID, Double) -> Void)?
    public var onOpRejected: ((String) -> Void)?
    public var onMemberAdded: ((Member) -> Void)?
    public var onMemberRemoved: ((String) -> Void)?
    public var onMemberRoleChanged: ((String, Member.Role) -> Void)?
    public var onMemberPresenceChanged: ((String, Member.Presence) -> Void)?
    public var onSessionsSnapshot: (([Session]) -> Void)?
    public var onSessionAdded: ((Session) -> Void)?
    public var onSessionPhaseChanged: ((UUID, Session.Phase, String?) -> Void)?
    public var onSessionArmingChanged: ((UUID, ProcessSession.ArmingState) -> Void)?
    public var onSessionModulesUpdated: ((UUID, ModuleDelta) -> Void)?
    public var onSessionThreadsUpdated: ((UUID, ThreadDelta) -> Void)?
    public var onSessionHostChanged: ((UUID, UserInfo, String, String, UInt, String) -> Void)?
    public var onSessionReplCellAdded: ((UUID, REPLCell) -> Void)?
    public var onSessionReplCellUpdated: ((UUID, REPLCell) -> Void)?
    public var onSessionReplEvalRequested: ((UUID, String, REPLLanguage, UUID) -> Void)?
    public var onSessionInstrumentAdded: ((UUID, InstrumentInstance) -> Void)?
    public var onSessionInstrumentUpdated: ((UUID, InstrumentInstance) -> Void)?
    public var onSessionInstrumentAgentReported: ((UUID, InstrumentAgentState) -> Void)?
    public var onSessionInstrumentRemoved: ((UUID, UUID) -> Void)?
    public var onSessionInstrumentSetStateRequested: ((UUID, UUID, InstrumentState) -> Void)?
    public var onSessionInstrumentRemoveRequested: ((UUID, UUID) -> Void)?
    public var onSessionInstrumentAddRequested: ((UUID, InstrumentKind, String, Data) -> Void)?
    public var onSessionInstrumentUpdateConfigRequested: ((UUID, UUID, Data) -> Void)?
    public var onSessionInsightAdded: ((UUID, AddressInsight) -> Void)?
    public var onSessionInsightUpdated: ((UUID, AddressInsight) -> Void)?
    public var onSessionPlacementsSet: ((UUID, SessionOp.SetPlacements.Subject, [PatternPlacement]) -> Void)?
    public var onSessionInsightRemoved: ((UUID, UUID) -> Void)?
    public var onSessionProcessInfoUpdated: ((UUID, ProcessSession.ProcessInfo) -> Void)?
    public var onSessionModuleAnalysisUpdated: ((UUID, ModuleAnalysis) -> Void)?
    public var onSessionModuleSymbolsUpdated: ((UUID, [SessionOp.UpdateModuleSymbols.Entry]) -> Void)?
    public var onSessionTraceUpserted: ((UUID, ITrace) -> Void)?
    public var onSessionTraceRemoved: ((UUID, UUID) -> Void)?
    public var onSessionTraceDataProgressed: ((UUID, UUID, Int) -> Void)?
    public var onSessionEventReceived: ((UUID, RuntimeEvent) -> Void)?
    public var onSessionEventUpdated: ((UUID, RuntimeEvent) -> Void)?
    public var onSessionWidgetUpdateReceived: ((UUID, WidgetUpdate) -> Void)?
    public var onSessionWidgetActionRequested: ((UUID, UUID, String, String, String?) -> Void)?
    public var onSessionViewStateReceived: ((UUID, UUID, String, WidgetViewState) -> Void)?
    public var onSessionViewEventReceived: ((UUID, UUID, String, WidgetViewPayload) -> Void)?
    public var onSessionViewMessageReceived: ((UUID, UUID, String, WidgetViewPayload, UserInfo) -> Void)?
    public var onSessionViewRefused: ((UUID, UUID, String, String) -> Void)?
    public var onReplEvalTimedOut: ((UUID) -> Void)?
    public var onSessionRemoved: ((UUID) -> Void)?
    public var onCustomInstrumentOpReceived: ((CustomInstrumentOp, UserInfo?) -> Void)?
    public var onMissionOpReceived: ((MissionOp) -> Void)?
    public var onAddressNoteOpReceived: ((AddressNoteOp) -> Void)?
    public var onObjectChatOpReceived: ((ObjectChatOp) -> Void)?
    public var onObjectChatMessageRefused: ((ObjectChatMessage, String) -> Void)?
    public var onObjectChatOpRefused: ((ObjectChatOp, String) -> Void)?
    public var onMissionRemovedInLab: ((UUID) -> Void)?
    public var onCustomInstrumentRemovedInLab: ((UUID) -> Void)?
    public var onPatternRemovedInLab: ((UUID) -> Void)?
    public var onMissionSnapshot: ((MissionSnapshot) -> Void)?
    public var onCustomInstrumentSnapshot: (([CustomInstrumentBundle], [UUID: UserInfo]) -> Void)?
    public var onPatternSourceOpReceived: ((PatternSourceOp) -> Void)?
    public var onPatternSourcesSnapshot: (([PatternSourceRecord]) -> Void)?
    public var onPatternSourceNameTaken: ((PatternSourceRecord) -> Void)?
    public var onLabCreated: (() -> Void)?
    public var onWidgetStatesSnapshot: (([WidgetStateSnapshot]) -> Void)?
    public var onWidgetPlacementsSnapshot: (([UUID: [String: [PatternPlacement]]]) -> Void)?
    public var onAddressNotesSnapshot: (([AddressNoteThread], Set<UUID>) -> Void)?
    public var onObjectChatsSnapshot: (([ObjectChatThread]) -> Void)?

    public var onAuthRejected: ((AuthFailure) async -> Void)?

    public init(connection: PortalConnection, store: ProjectStore) {
        self.connection = connection
        self.store = store
        membership = (try? store.fetchCollaborationState().labID).flatMap { try? store.fetchLabMembership(labID: $0) }
        localUser = membership?.user
    }

    public func start(token: String, existingLabID: String?) async {
        guard case .disconnected = status else { return }
        setStatus(.connecting)

        do {
            let lease = try await connection.retain(token: token) { [weak self] event in
                self?.handlePortalEvent(event)
            }
            guard case .connecting = status else {
                await lease.release()
                return
            }
            portalLease = lease

            if let existingLabID {
                pendingJoinLabID = existingLabID
            }
            applyWelcome(lease.welcome)
            triggerJoinOrCreateIfReady()
        } catch {
            if let failure = AuthFailure.fromError(error), failure.isAuthRejection {
                setStatus(.error(message: failure.message))
                await onAuthRejected?(failure)
            } else {
                setStatus(.error(message: error.localizedDescription))
            }
        }
    }

    public func stop() async {
        await portalLease?.release()
        portalLease = nil

        setStatus(.disconnected)
        labID = nil
        labTitle = nil
        labPictureData = nil
        labPictureContentType = nil
        localUser = membership?.user
        pendingJoinLabID = nil
        opsOverridingJoinSnapshot = [:]
        pendingCreateOrJoinDispatched = false
        members = []
        vapidPublicKey = nil
        registeredPushPlatforms = []
    }

    func sendRequest(
        to path: String,
        type: String,
        payload: JSONObject = [:],
        data: [UInt8]? = nil,
        onResult: @escaping (Result<PortalConnection.Reply, AuthFailure>) -> Void
    ) {
        guard let portalLease else { return }
        portalLease.request(to: path, type: type, payload: payload, data: data, onReply: onResult)
    }

    func sendNotification(
        to path: String,
        type: String,
        payload: JSONObject,
        data: [UInt8]? = nil
    ) {
        guard let portalLease else { return }
        portalLease.notify(to: path, type: type, payload: payload, data: data)
    }

    /// True once this project has ever joined or created a lab. Local-only
    /// projects skip the outbox entirely so they never touch that table.
    private static let patternNameTaken = "upsert: name taken"

    public var isCollaborative: Bool {
        (try? store.fetchCollaborationState())?.labID != nil
    }

    public func enqueueAdd(_ entry: NotebookEntry) {
        guard isCollaborative else { return }
        let op = NotebookOp.add(.init(entry: entry))
        try? store.saveOutboxOps([op])
        sendOpIfJoined(op)
    }

    public func enqueueUpdate(
        entryID: UUID,
        title: String? = nil,
        details: String? = nil,
        processName: String? = nil,
        pharoSnapshot: PharoSnapshot? = nil,
        pharoResultFuel: Data? = nil,
        jsValue: JSInspectValue? = nil,
        placements: [PatternPlacement]? = nil,
        placementSnapshots: [PlacementSnapshot]? = nil
    ) {
        guard isCollaborative else { return }
        let op = NotebookOp.update(.init(
            entryID: entryID,
            title: title,
            details: details,
            processName: processName,
            pharoSnapshot: pharoSnapshot,
            pharoResultFuel: pharoResultFuel,
            jsValue: jsValue,
            placements: placements,
            placementSnapshots: placementSnapshots
        ))
        try? store.saveOutboxOps([op])
        sendOpIfJoined(op)
    }

    public func enqueueRemove(entryID: UUID) {
        guard isCollaborative else { return }
        let op = NotebookOp.remove(.init(entryID: entryID))
        try? store.saveOutboxOps([op])
        sendOpIfJoined(op)
    }

    public func enqueueCustomInstrumentOp(_ op: CustomInstrumentOp) {
        guard isCollaborative, !isWithheld(LabSubject(.definition, op.defID)) else { return }
        try? store.saveOutboxOps([op])
        guard case .joined(let labID) = status else { return }
        sendCustomInstrumentOpOverWire(op, labID: labID)
    }

    private func sendCustomInstrumentOpOverWire(_ op: CustomInstrumentOp, labID: String) {
        sendNotification(
            to: "/labs/\(labID)/custom-instruments",
            type: "+op",
            payload: op.toJSON()
        )
    }

    public func enqueueReorder(entryID: UUID, position: Double) {
        guard isCollaborative else { return }
        let op = NotebookOp.reorder(.init(entryID: entryID, position: position))
        try? store.saveOutboxOps([op])
        sendOpIfJoined(op)
    }

    public func enqueueMission(_ mission: Mission) {
        for op in missionOps(announcing: mission) {
            enqueueMissionOp(op)
        }
    }

    public func enqueueMissionUpsert(_ mission: Mission) {
        enqueueMissionOp(.missionUpsert(.init(mission: mission)))
    }

    public func enqueueMissionRemove(missionID: UUID) {
        enqueueMissionOp(.missionRemove(.init(missionID: missionID)))
    }

    public func enqueueMissionTurn(_ turn: MissionTurn) {
        enqueueMissionOp(.turnAppend(.init(turn: turn)))
    }

    public func enqueueMissionAction(_ action: MissionAction) {
        enqueueMissionOp(.actionUpsert(.init(action: action)))
    }

    public func enqueueMissionFinding(_ finding: MissionFinding) {
        enqueueMissionOp(.findingUpsert(.init(finding: finding)))
    }

    public func enqueueMissionFindingRemove(missionID: UUID, findingID: UUID) {
        enqueueMissionOp(.findingRemove(.init(missionID: missionID, findingID: findingID)))
    }

    public func enqueueMissionEvidence(missionID: UUID, evidence: MissionEvidence) {
        enqueueMissionOp(.evidenceAdd(.init(missionID: missionID, evidence: evidence)))
    }

    public func enqueueMissionSteer(_ steer: MissionSteer) {
        enqueueMissionOp(.steerAppend(.init(steer: steer)))
    }

    public func enqueueMissionSteerConsumed(missionID: UUID, steerIDs: [UUID]) {
        enqueueMissionOp(.steerConsume(.init(missionID: missionID, steerIDs: steerIDs)))
    }

    public func forget(removedMission missionID: UUID) {
        removedMissionIDs.insert(missionID)
        try? store.removeOutboxOps(family: MissionOp.outboxFamily, subject: missionID)
    }

    private func enqueueMissionOp(_ op: MissionOp) {
        guard isCollaborative, !removedMissionIDs.contains(op.missionID) || op.kind == "mission_remove" else { return }
        try? store.saveOutboxOps([op])
        sendMissionOpIfJoined(op)
    }

    private func sendMissionOpIfJoined(_ op: MissionOp) {
        guard case .joined(let labID) = status else { return }
        sendMissionOpOverWire(op, labID: labID)
    }

    private func sendMissionOpOverWire(_ op: MissionOp, labID: String) {
        sendNotification(
            to: "/labs/\(labID)/missions",
            type: "+op",
            payload: op.toJSON()
        )
    }

    public func enqueueAddressNoteUpsert(_ note: AddressNote) {
        enqueueAddressNoteOp(.noteUpsert(.init(note: note)))
    }

    public func enqueueAddressNoteRemove(noteID: UUID) {
        enqueueAddressNoteOp(.noteRemove(.init(noteID: noteID)))
    }

    public func enqueueAddressNoteMessageAppend(_ message: AddressNoteMessage) {
        enqueueAddressNoteOp(.messageAppend(.init(message: message)))
    }

    public func enqueueAddressNoteMessageEdit(noteID: UUID, messageID: UUID, bodyMarkdown: String) {
        enqueueAddressNoteOp(.messageEdit(.init(noteID: noteID, messageID: messageID, bodyMarkdown: bodyMarkdown)))
    }

    public func enqueueAddressNoteMessageRemove(noteID: UUID, messageID: UUID) {
        enqueueAddressNoteOp(.messageRemove(.init(noteID: noteID, messageID: messageID)))
    }

    private func enqueueAddressNoteOp(_ op: AddressNoteOp) {
        guard isCollaborative else { return }
        try? store.saveOutboxOps([op])
        sendAddressNoteOpIfJoined(op)
    }

    private func sendAddressNoteOpIfJoined(_ op: AddressNoteOp) {
        guard case .joined(let labID) = status else { return }
        sendAddressNoteOpOverWire(op, labID: labID)
    }

    private func sendAddressNoteOpOverWire(_ op: AddressNoteOp, labID: String) {
        sendNotification(
            to: "/labs/\(labID)/address-notes",
            type: "+op",
            payload: op.toJSON()
        )
    }

    public func enqueueObjectChat(_ change: ObjectChatOp.Change) throws {
        guard isCollaborative else { return }
        let op = ObjectChatOp(change)
        try store.saveOutboxOps([op])
        guard case .joined(let labID) = status else { return }
        sendObjectChatOpOverWire(op, labID: labID)
    }

    private func sendObjectChatOpOverWire(_ op: ObjectChatOp, labID: String) {
        sendNotification(
            to: "/labs/\(labID)/object-chats",
            type: "+op",
            payload: op.toJSON()
        )
    }

    public func enqueuePatternSourceUpsert(_ record: PatternSourceRecord) {
        enqueuePatternSourceOp(.upsert(.init(record: record)))
    }

    public func enqueuePatternSourceRemove(sourceID: UUID) {
        enqueuePatternSourceOp(.remove(.init(sourceID: sourceID)))
    }

    private func enqueuePatternSourceOp(_ op: PatternSourceOp) {
        guard isCollaborative, !isWithheld(LabSubject(.pattern, op.sourceID)) else { return }
        try? store.saveOutboxOps([op])
        guard case .joined(let labID) = status else { return }
        sendPatternSourceOpOverWire(op, labID: labID)
    }

    private func isWithheld(_ subject: LabSubject) -> Bool {
        ((try? store.subjectsWithheldFromLab()) ?? []).contains(subject)
    }

    private func sendPatternSourceOpOverWire(_ op: PatternSourceOp, labID: String) {
        sendNotification(
            to: "/labs/\(labID)/patterns",
            type: "+op",
            payload: op.toJSON()
        )
    }

    private func replayOutbox(knownSessions: Set<UUID>, announcingTheRest announce: () -> Void) {
        guard case .joined(let labID) = status else { return }
        let queued = (try? store.fetchOutbox()) ?? []
        let awaitingAnnouncement = queued.filter { Self.isOp($0, ofSessionOtherThan: knownSessions) }
        for op in queued where !Self.isOp(op, ofSessionOtherThan: knownSessions) {
            if case .session(let sessionOp) = op {
                opsOverridingJoinSnapshot[sessionOp.opID] = sessionOp
            }
            replay(op, labID: labID)
        }
        announce()
        for op in awaitingAnnouncement {
            replay(op, labID: labID)
        }
    }

    private static func isOp(_ op: QueuedOp, ofSessionOtherThan sessionIDs: Set<UUID>) -> Bool {
        guard case .session(let sessionOp) = op else { return false }
        return !sessionIDs.contains(sessionOp.sessionID)
    }

    private func replay(_ op: QueuedOp, labID: String) {
        switch op {
        case .notebook(let op):
            replayedOpIDs.insert(op.opID)
            sendOpOverWire(op, labID: labID)
        case .session(let op):
            sendSessionOpOverWire(op, labID: labID)
        case .customInstrument(let op):
            replayedOpIDs.insert(op.opID)
            sendCustomInstrumentOpOverWire(op, labID: labID)
        case .pattern(let op):
            replayedOpIDs.insert(op.opID)
            sendPatternSourceOpOverWire(op, labID: labID)
        case .mission(let op):
            replayedOpIDs.insert(op.opID)
            sendMissionOpOverWire(op, labID: labID)
        case .addressNote(let op):
            replayedOpIDs.insert(op.opID)
            sendAddressNoteOpOverWire(op, labID: labID)
        case .objectChat(let op):
            replayedOpIDs.insert(op.opID)
            sendObjectChatOpOverWire(op, labID: labID)
        }
    }

    private func sendOpIfJoined(_ op: NotebookOp) {
        guard case .joined(let labID) = status else { return }
        sendOpOverWire(op, labID: labID)
    }

    private func sendOpOverWire(_ op: NotebookOp, labID: String) {
        var binary: [UInt8]? = nil
        if case let .add(add) = op, let bin = add.entry.binaryData {
            binary = [UInt8](bin)
        }
        sendNotification(
            to: "/labs/\(labID)/notebook/entries",
            type: "+op",
            payload: op.toJSON(),
            data: binary
        )
    }

    public func registerPushSubscriptions(_ subs: [JSONObject]) {
        guard let localUser else { return }
        sendNotification(
            to: "/users/\(localUser.id)/push_subscriptions",
            type: "+add",
            payload: ["subscriptions": subs]
        )
        for s in subs {
            if let platform = s["platform"] as? String {
                registeredPushPlatforms.insert(platform)
            }
        }
    }

    public func unregisterPushSubscriptions(_ subs: [JSONObject]) {
        guard let localUser else { return }
        sendNotification(
            to: "/users/\(localUser.id)/push_subscriptions",
            type: "+remove",
            payload: ["subscriptions": subs]
        )
    }

    public struct PushEnrollmentTicket: Sendable {
        public let token: String
        public let vapidPublicKey: String
    }

    public func requestPushEnrollmentToken() async throws -> PushEnrollmentTicket {
        guard let userID = localUser?.id else {
            throw AuthFailure(
                domain: "client",
                code: "not-authenticated",
                message: "No authenticated user",
            )
        }
        return try await withCheckedThrowingContinuation { cont in
            sendRequest(
                to: "/users/\(userID)/push_enrollment_tokens",
                type: ".create"
            ) { result in
                switch result {
                case .success(let reply):
                    guard let token = reply.payload["token"] as? String,
                        let vapid = reply.payload["vapid_public_key"] as? String
                    else {
                        cont.resume(throwing: AuthFailure(
                            domain: "portal",
                            code: "bad-response",
                            message: "Missing fields in enrollment response",
                        ))
                        return
                    }
                    cont.resume(returning: PushEnrollmentTicket(
                        token: token, vapidPublicKey: vapid
                    ))
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
        }
    }

    /// Rename the active lab. Owner-only — the server rejects everyone
    /// else with `forbidden`. Optimistically updates `labTitle` on success
    /// so the UI doesn't wait for the broadcast echo to reflect the new
    /// value.
    public func setLabTitle(_ title: String) async {
        guard case .joined(let labID) = status else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sendRequest(
                to: "/labs/\(labID)",
                type: ".set",
                payload: ["title": trimmed]
            ) { [weak self] result in
                if case .success = result {
                    self?.labTitle = trimmed
                }
                cont.resume()
            }
        }
    }

    /// Upload a new lab picture. Owner-only. `contentType` is one of
    /// image/png, image/jpeg, image/webp, image/gif. Data is capped at
    /// 512 KiB by the server. Updates `labPictureData` optimistically on
    /// success.
    public func setLabPicture(_ data: Data, contentType: String) async {
        guard case .joined(let labID) = status else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sendRequest(
                to: "/labs/\(labID)/picture",
                type: ".set",
                payload: ["content_type": contentType],
                data: [UInt8](data)
            ) { [weak self] result in
                if case .success = result {
                    self?.labPictureData = data
                    self?.labPictureContentType = contentType
                }
                cont.resume()
            }
        }
    }

    /// Suggested title for a freshly-created lab, built from the local
    /// weekday and time-of-day plus a randomly-picked verb, e.g.
    /// "Monday morning reversing", "Friday evening spelunking". Generated
    /// client-side so the weekday/time reflect the owner's timezone, not
    /// the server's.
    public static func initialLabTitle(at date: Date = .now) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let weekdays = [
            "Sunday", "Monday", "Tuesday", "Wednesday",
            "Thursday", "Friday", "Saturday",
        ]
        let weekday = weekdays[cal.component(.weekday, from: date) - 1]
        let hour = cal.component(.hour, from: date)
        let timeOfDay: String
        switch hour {
        case 4..<12: timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        case 17..<21: timeOfDay = "evening"
        default: timeOfDay = "night"
        }
        let verbs = [
            "reversing", "tracing", "hacking", "spelunking",
            "poking", "sleuthing", "dissecting",
        ]
        return "\(weekday) \(timeOfDay) \(verbs.randomElement()!)"
    }

    public func setMemberRole(userID: String, role: Member.Role) async {
        guard case .joined(let labID) = status else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sendRequest(
                to: "/labs/\(labID)/members/\(userID)/role",
                type: ".set",
                payload: ["role": role.rawValue]
            ) { _ in cont.resume() }
        }
    }

    public func removeMembers(_ userIDs: [String]) async {
        guard case .joined(let labID) = status else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sendRequest(
                to: "/labs/\(labID)/members",
                type: ".remove",
                payload: ["user_ids": userIDs]
            ) { _ in cont.resume() }
        }
    }

    public func leaveLab() async {
        guard case .joined(let labID) = status else { return }
        let succeeded: Bool = await withCheckedContinuation { cont in
            sendRequest(to: "/labs/\(labID)", type: ".leave") { result in
                if case .success = result {
                    cont.resume(returning: true)
                } else {
                    cont.resume(returning: false)
                }
            }
        }
        guard succeeded else { return }
        var collabState = try! store.fetchCollaborationState()
        collabState.labID = nil
        try! store.save(collabState)
        try! store.deleteLabMemberships()
        membership = nil
        await stop()
    }

    @discardableResult
    public func enqueueAddSession(
        sessionID: UUID,
        deviceID: String,
        deviceName: String,
        pid: UInt,
        processName: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) -> SessionOp? {
        guard let localUser else { return nil }
        let op = SessionOp.add(.init(
            sessionID: sessionID,
            host: localUser,
            deviceID: deviceID,
            deviceName: deviceName,
            pid: pid,
            processName: processName,
            createdAt: createdAt
        ))
        enqueueSessionOp(op)
        return op
    }

    public func enqueueUpdateSessionPhase(
        sessionID: UUID,
        phase: Session.Phase,
        reason: String? = nil,
        lastSeenAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        enqueueSessionOp(.updatePhase(.init(
            sessionID: sessionID,
            phase: phase,
            reason: reason,
            lastSeenAt: lastSeenAt
        )))
    }

    public func enqueueUpdateSessionArming(
        sessionID: UUID,
        armingState: ProcessSession.ArmingState
    ) {
        enqueueSessionOp(.updateArming(.init(
            sessionID: sessionID,
            armingState: armingState
        )))
    }

    public func enqueueUpdateSessionModules(sessionID: UUID, delta: ModuleDelta) {
        guard !delta.isEmpty else { return }
        enqueueSessionOp(.updateModules(.init(
            sessionID: sessionID,
            delta: delta
        )))
    }

    public func enqueueUpdateSessionThreads(sessionID: UUID, delta: ThreadDelta) {
        guard !delta.isEmpty else { return }
        enqueueSessionOp(.updateThreads(.init(
            sessionID: sessionID,
            delta: delta
        )))
    }

    public func enqueueRemoveSession(sessionID: UUID) {
        enqueueSessionOp(.remove(.init(sessionID: sessionID)))
    }

    public func requestClaimHost(
        sessionID: UUID,
        deviceID: String,
        deviceName: String,
        pid: UInt,
        processName: String
    ) async throws {
        guard case .joined(let labID) = status, let localUser else {
            throw AuthFailure(domain: "client", code: "not-joined", message: "Not in a lab")
        }
        let op = SessionOp.claimHost(.init(
            sessionID: sessionID,
            host: localUser,
            deviceID: deviceID,
            deviceName: deviceName,
            pid: pid,
            processName: processName
        ))
        try await withCheckedThrowingContinuation { cont in
            sendRequest(
                to: "/labs/\(labID)/sessions/\(sessionID.uuidString)",
                type: ".claim-host",
                payload: op.toJSON()
            ) { result in
                switch result {
                case .success:
                    cont.resume(returning: ())
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
        }
    }

    public func enqueueAddReplCell(sessionID: UUID, cell: REPLCell) {
        var wireCell = cell
        wireCell.sessionID = sessionID
        enqueueSessionOp(.addReplCell(.init(sessionID: sessionID, cell: wireCell)))
    }

    public func enqueueUpdateReplCell(sessionID: UUID, cell: REPLCell) {
        var wireCell = cell
        wireCell.sessionID = sessionID
        enqueueSessionOp(.updateReplCell(.init(sessionID: sessionID, cell: wireCell)))
    }

    public func enqueueAddInstrument(
        sessionID: UUID,
        instance: InstrumentInstance,
        runtimeStatus: InstrumentStatus? = nil,
        agent: InstrumentAgentState? = nil
    ) {
        var wireInst = instance
        wireInst.sessionID = sessionID
        enqueueSessionOp(.addInstrument(.init(sessionID: sessionID, instance: wireInst, runtimeStatus: runtimeStatus, agent: agent)))
    }

    public func enqueueUpdateInstrument(
        sessionID: UUID,
        instance: InstrumentInstance,
        runtimeStatus: InstrumentStatus? = nil,
        agent: InstrumentAgentState? = nil
    ) {
        var wireInst = instance
        wireInst.sessionID = sessionID
        enqueueSessionOp(.updateInstrument(.init(sessionID: sessionID, instance: wireInst, runtimeStatus: runtimeStatus, agent: agent)))
    }

    public func enqueueRemoveInstrument(sessionID: UUID, instanceID: UUID) {
        enqueueSessionOp(.removeInstrument(.init(sessionID: sessionID, instanceID: instanceID)))
    }

    public func enqueueAddInsight(sessionID: UUID, insight: AddressInsight) {
        var wireInsight = insight
        wireInsight.sessionID = sessionID
        enqueueSessionOp(.addInsight(.init(sessionID: sessionID, insight: wireInsight)))
    }

    public func enqueueUpdateInsight(sessionID: UUID, insight: AddressInsight) {
        var wireInsight = insight
        wireInsight.sessionID = sessionID
        enqueueSessionOp(.updateInsight(.init(sessionID: sessionID, insight: wireInsight)))
    }

    public func enqueueRemoveInsight(sessionID: UUID, insightID: UUID) {
        enqueueSessionOp(.removeInsight(.init(sessionID: sessionID, insightID: insightID)))
    }

    public func enqueueSetPlacements(_ placements: [PatternPlacement], sessionID: UUID, on subject: SessionOp.SetPlacements.Subject) {
        enqueueSessionOp(.setPlacements(.init(sessionID: sessionID, subject: subject, placements: placements)))
    }

    public func enqueueUpdateProcessInfo(sessionID: UUID, info: ProcessSession.ProcessInfo) {
        enqueueSessionOp(.updateProcessInfo(.init(sessionID: sessionID, info: info)))
    }

    public func enqueueUpdateModuleSymbols(sessionID: UUID, entries: [SessionOp.UpdateModuleSymbols.Entry]) {
        guard !entries.isEmpty else { return }
        enqueueSessionOp(.updateModuleSymbols(.init(sessionID: sessionID, entries: entries)))
    }

    public func enqueueUpdateModuleAnalysis(sessionID: UUID, analysis: ModuleAnalysis) {
        var wire = analysis
        wire.sessionID = sessionID
        enqueueSessionOp(.updateModuleAnalysis(.init(sessionID: sessionID, analysis: wire)))
    }

    public func publishMemoryPage(sessionID: UUID, _ page: MemoryPagePublish) {
        guard case .joined(let labID) = status else { return }
        var payload: JSONObject = [
            "op_id": UUID().uuidString,
            "kind": "publish-memory-page",
        ]
        switch page.region {
        case .module(let uuid, let offset):
            payload["region"] = "module"
            payload["module_uuid"] = uuid
            payload["offset"] = Int64(bitPattern: offset)
        case .anonymous(let identity, let address):
            payload["region"] = "anonymous"
            payload["process_identity"] = identity
            payload["address"] = Int64(bitPattern: address)
        }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)",
            type: "+op",
            payload: payload,
            data: [UInt8](page.bytes)
        )
    }

    public func fetchMemoryPage(sessionID: UUID, region: MemoryPageRegion) async -> Data? {
        guard case .joined(let labID) = status else { return nil }
        var payload: JSONObject = [:]
        switch region {
        case .module(let uuid, let offset):
            payload["region"] = "module"
            payload["module_uuid"] = uuid
            payload["offset"] = Int64(bitPattern: offset)
        case .anonymous(let identity, let address):
            payload["region"] = "anonymous"
            payload["process_identity"] = identity
            payload["address"] = Int64(bitPattern: address)
        }
        return await withCheckedContinuation { continuation in
            sendRequest(
                to: "/labs/\(labID)/sessions/\(sessionID.uuidString)",
                type: "+fetch-memory-page",
                payload: payload
            ) { result in
                switch result {
                case .success(let reply):
                    let present = (reply.payload["present"] as? Bool) ?? false
                    let bytes = reply.data ?? []
                    continuation.resume(returning: present ? Data(bytes) : nil)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func uploadTraceData(sessionID: UUID, traceID: UUID, offset: Int, chunk: Data) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)",
            type: "+op",
            payload: [
                "op_id": UUID().uuidString,
                "kind": "set-trace-data",
                "trace_id": traceID.uuidString,
                "offset": offset,
            ],
            data: [UInt8](chunk)
        )
    }

    public func fetchTraceData(
        sessionID: UUID,
        traceID: UUID,
        offset: Int = 0,
        length: Int? = nil
    ) async throws -> (data: Data, totalSize: Int) {
        guard case .joined(let labID) = status else {
            throw LumaCoreError.invalidOperation("Not joined to a lab")
        }
        var payload: JSONObject = ["offset": offset]
        if let length { payload["length"] = length }

        return try await withCheckedThrowingContinuation { continuation in
            sendRequest(
                to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/traces/\(traceID.uuidString)",
                type: "+fetch",
                payload: payload
            ) { result in
                switch result {
                case .success(let reply):
                    let total = (reply.payload["total_size"] as? Int) ?? 0
                    let bytes = reply.data ?? []
                    continuation.resume(returning: (Data(bytes), total))
                case .failure(let failure):
                    continuation.resume(throwing: failure)
                }
            }
        }
    }

    public func enqueueUpsertTrace(sessionID: UUID, trace: ITrace) {
        var wireTrace = trace
        wireTrace.sessionID = sessionID
        enqueueSessionOp(.upsertTrace(.init(sessionID: sessionID, trace: wireTrace)))
    }

    public func enqueueRemoveTrace(sessionID: UUID, traceID: UUID) {
        enqueueSessionOp(.removeTrace(.init(sessionID: sessionID, traceID: traceID)))
    }

    public func sendEvent(sessionID: UUID, event: RuntimeEvent) {
        guard case .joined(let labID) = status,
            let wirePayload = event.toWireJSON()
        else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/events",
            type: "+event",
            payload: wirePayload
        )
    }

    public func sendEventUpdate(sessionID: UUID, event: RuntimeEvent) {
        guard case .joined(let labID) = status,
            let wirePayload = event.toWireJSON()
        else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/events",
            type: "+event-update",
            payload: wirePayload
        )
    }

    public func sendWidgetUpdate(sessionID: UUID, update: WidgetUpdate) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/widget-updates",
            type: "+widget-update",
            payload: update.toWireJSON()
        )
    }

    public func sendWidgetAction(
        sessionID: UUID,
        instanceID: UUID,
        widget: String,
        action: String,
        item: String?
    ) {
        guard case .joined(let labID) = status else { return }
        var payload: [String: Any] = [
            "instance_id": instanceID.uuidString,
            "widget": widget,
            "action": action,
        ]
        if let item { payload["item"] = item }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/widget-actions",
            type: "+widget-action",
            payload: payload
        )
    }


    public func sendReplEvalRequest(sessionID: UUID, code: String, language: REPLLanguage, cellID: UUID) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/repl/cells/\(cellID.uuidString)",
            type: "+eval",
            payload: ["code": code, "language": language.rawValue]
        )
        schedulePendingReplTimeout(cellID: cellID)
    }

    private static let replEvalTimeout: UInt64 = 30_000_000_000

    @ObservationIgnored private var pendingReplTimeouts: [UUID: Task<Void, Never>] = [:]

    private func schedulePendingReplTimeout(cellID: UUID) {
        pendingReplTimeouts[cellID]?.cancel()
        pendingReplTimeouts[cellID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.replEvalTimeout)
            guard !Task.isCancelled, let self else { return }
            self.pendingReplTimeouts.removeValue(forKey: cellID)
            self.onReplEvalTimedOut?(cellID)
        }
    }

    private func cancelPendingReplTimeout(cellID: UUID) {
        pendingReplTimeouts.removeValue(forKey: cellID)?.cancel()
    }

    public func sendInstrumentSetState(sessionID: UUID, instanceID: UUID, state: InstrumentState) {
        guard case .joined(let labID) = status else { return }
        let verb: String = state == .enabled ? "+enable" : "+disable"
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/instruments/\(instanceID.uuidString)",
            type: verb,
            payload: [:]
        )
    }

    public func sendInstrumentRemove(sessionID: UUID, instanceID: UUID) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/instruments/\(instanceID.uuidString)",
            type: "+remove",
            payload: [:]
        )
    }

    public func sendInstrumentAdd(
        sessionID: UUID,
        kind: InstrumentKind,
        sourceIdentifier: String,
        configJSON: Data
    ) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/instruments",
            type: "+add",
            payload: [
                "kind": kind.rawValue,
                "source_identifier": sourceIdentifier,
                "config_json": configJSON.base64EncodedString(),
            ]
        )
    }

    public func sendInstrumentUpdateConfig(
        sessionID: UUID,
        instanceID: UUID,
        configJSON: Data
    ) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/instruments/\(instanceID.uuidString)",
            type: "+update-config",
            payload: ["config_json": configJSON.base64EncodedString()]
        )
    }

    private func enqueueSessionOp(_ op: SessionOp) {
        guard isCollaborative else { return }
        try? store.saveOutboxOps([op])
        sendSessionOpIfJoined(op)
    }

    private func sendSessionOpIfJoined(_ op: SessionOp) {
        guard case .joined(let labID) = status else { return }
        sendSessionOpOverWire(op, labID: labID)
    }

    private func sendSessionOpOverWire(_ op: SessionOp, labID: String) {
        sendNotification(
            to: "/labs/\(labID)/sessions/\(op.sessionID.uuidString)",
            type: "+op",
            payload: op.toJSON()
        )
    }

    private func applySessionOp(sessionID: UUID, payload: JSONObject) {
        guard let op = SessionOp.fromJSON(payload, sessionID: sessionID) else { return }
        markKnown(op.labSubject)
        apply(op)
    }

    private func apply(_ op: SessionOp) {
        switch op {
        case .add(let a):
            let session = Session(
                id: a.sessionID,
                host: a.host,
                deviceID: a.deviceID,
                deviceName: a.deviceName,
                pid: a.pid,
                processName: a.processName,
                phase: .attaching,
                createdAt: a.createdAt,
                lastSeenAt: a.createdAt,
                modules: []
            )
            onSessionAdded?(session)

        case .updatePhase(let u):
            onSessionPhaseChanged?(u.sessionID, u.phase, u.reason)

        case .updateProcessInfo(let u):
            onSessionProcessInfoUpdated?(u.sessionID, u.info)

        case .updateArming(let u):
            onSessionArmingChanged?(u.sessionID, u.armingState)

        case .updateModules(let u):
            onSessionModulesUpdated?(u.sessionID, u.delta)

        case .updateModuleAnalysis(let u):
            onSessionModuleAnalysisUpdated?(u.sessionID, u.analysis)

        case .updateModuleSymbols(let u):
            onSessionModuleSymbolsUpdated?(u.sessionID, u.entries)

        case .updateThreads(let u):
            onSessionThreadsUpdated?(u.sessionID, u.delta)

        case .claimHost(let c):
            onSessionHostChanged?(
                c.sessionID, c.host, c.deviceID, c.deviceName, c.pid, c.processName
            )

        case .addReplCell(let a):
            cancelPendingReplTimeout(cellID: a.cell.id)
            onSessionReplCellAdded?(a.sessionID, a.cell)

        case .updateReplCell(let u):
            onSessionReplCellUpdated?(u.sessionID, u.cell)

        case .addInstrument(let a):
            if let agent = a.agent {
                onSessionInstrumentAgentReported?(a.instance.id, agent)
            }
            onSessionInstrumentAdded?(a.sessionID, a.instance)

        case .updateInstrument(let u):
            if let agent = u.agent {
                onSessionInstrumentAgentReported?(u.instance.id, agent)
            }
            onSessionInstrumentUpdated?(u.sessionID, u.instance)

        case .removeInstrument(let r):
            onSessionInstrumentRemoved?(r.sessionID, r.instanceID)

        case .addInsight(let a):
            onSessionInsightAdded?(a.sessionID, a.insight)

        case .updateInsight(let u):
            onSessionInsightUpdated?(u.sessionID, u.insight)

        case .removeInsight(let r):
            onSessionInsightRemoved?(r.sessionID, r.insightID)

        case .setPlacements(let s):
            onSessionPlacementsSet?(s.sessionID, s.subject, s.placements)

        case .upsertTrace(let u):
            onSessionTraceUpserted?(u.sessionID, u.trace)

        case .removeTrace(let r):
            onSessionTraceRemoved?(r.sessionID, r.traceID)

        case .traceDataProgressed(let t):
            onSessionTraceDataProgressed?(t.sessionID, t.traceID, t.totalSize)

        case .remove(let r):
            onSessionRemoved?(r.sessionID)
        }
    }

    private func triggerJoinOrCreateIfReady() {
        guard !pendingCreateOrJoinDispatched else { return }
        guard case .connecting = status else { return }
        pendingCreateOrJoinDispatched = true
        if let labID = pendingJoinLabID {
            pendingJoinLabID = nil
            joinLab(labID: labID)
        } else {
            createLab()
        }
    }

    private func createLab() {
        setStatus(.connecting)
        let initialTitle = Self.initialLabTitle()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let creatorAvatar = await self.fetchCreatorAvatar() else {
                self.setStatus(.error(message: "Couldn't fetch your GitHub avatar to use as the lab picture."))
                return
            }
            self.sendCreateRequest(
                title: initialTitle,
                pictureData: creatorAvatar.data,
                pictureContentType: creatorAvatar.contentType
            )
        }
    }

    private func sendCreateRequest(title: String, pictureData: Data, pictureContentType: String) {
        sendRequest(
            to: "/labs",
            type: ".create",
            payload: [
                "title": title,
                "picture": ["content_type": pictureContentType],
            ],
            data: [UInt8](pictureData)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply):
                guard let labObj = reply.payload["lab"] as? JSONObject,
                    let labID = labObj["id"] as? String,
                    let localUser = self.localUser
                else { Task { await self.stop() }; return }
                self.labID = labID
                self.labTitle = (labObj["title"] as? String) ?? title
                self.labPictureData = pictureData
                self.labPictureContentType = pictureContentType
                // Persist labID first so isCollaborative flips true before
                // we fan existing entries into the outbox.
                var collabState = try! self.store.fetchCollaborationState()
                collabState.labID = labID
                try! self.store.save(collabState)
                self.remember(LabMembership(labID: labID, user: localUser, role: .owner))
                self.setStatus(.joined(labID: labID))
                let now = ISO8601DateFormatter().string(from: Date())
                self.members = [Member(
                    user: localUser,
                    role: .owner,
                    presence: .online,
                    joinedAt: now,
                    lastSeenAt: now
                )]
                try? self.store.forgetLabKnowledge()
                self.queueProjectForNewLab()
                self.replayOutbox(knownSessions: []) { self.onSessionsSnapshot?([]) }
                self.onLabCreated?()
            case .failure(let failure):
                self.setStatus(.error(message: failure.message))
            }
        }
    }

    private func remember(_ membership: LabMembership) {
        try! store.save(membership)
        self.membership = membership
    }

    private func queueProjectForNewLab() {
        let definitions = (try? store.fetchCustomInstrumentDefs()) ?? []
        try? store.saveOutboxOps(definitions.map { def in
            let files = (try? store.fetchCustomInstrumentFiles(defID: def.id)) ?? []
            return CustomInstrumentOp.upsert(.init(bundle: CustomInstrumentBundle(def: def, files: files)))
        })
        let patterns = (try? store.fetchPatternSources()) ?? []
        try? store.saveOutboxOps(patterns.map { PatternSourceOp.upsert(.init(record: $0)) })
        for mission in (try? store.fetchMissions()) ?? [] {
            try? store.saveOutboxOps(missionOps(announcing: mission))
        }
        let entries = (try? store.fetchNotebookEntries()) ?? []
        try? store.saveOutboxOps(entries.map { NotebookOp.add(.init(entry: $0)) })
    }

    private func missionOps(announcing mission: Mission) -> [MissionOp] {
        let turns = (try? store.fetchMissionTurns(missionID: mission.id)) ?? []
        let actions = (try? store.fetchMissionActions(missionID: mission.id)) ?? []
        let findings = (try? store.fetchMissionFindings(missionID: mission.id)) ?? []
        let evidence = findings.flatMap { (try? store.fetchMissionEvidence(findingID: $0.id)) ?? [] }
        return [.missionUpsert(.init(mission: mission))]
            + turns.map { .turnAppend(.init(turn: $0)) }
            + actions.map { .actionUpsert(.init(action: $0)) }
            + findings.map { .findingUpsert(.init(finding: $0)) }
            + evidence.map { .evidenceAdd(.init(missionID: mission.id, evidence: $0)) }
    }

    private struct AvatarBytes {
        let data: Data
        let contentType: String
    }

    private static let allowedAvatarContentTypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp", "image/gif",
    ]

    private func fetchCreatorAvatar() async -> AvatarBytes? {
        guard let baseURL = localUser?.avatarURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "s" }
        items.append(URLQueryItem(name: "s", value: "256"))
        components.queryItems = items
        guard let url = components.url else { return nil }
        let backoffs: [UInt64] = [0, 500_000_000, 2_000_000_000]
        for delay in backoffs {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                let raw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                let contentType = raw.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
                guard Self.allowedAvatarContentTypes.contains(contentType) else { return nil }
                return AvatarBytes(data: data, contentType: contentType)
            } catch {
                continue
            }
        }
        return nil
    }

    private func joinLab(labID: String) {
        setStatus(.connecting)
        sendRequest(
            to: "/labs/\(labID)",
            type: ".join"
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply):
                self.ingestJoinSnapshot(payload: reply.payload, data: reply.data, labID: labID)
            case .failure(let failure):
                self.setStatus(.error(message: failure.message))
            }
        }
    }

    private func ingestJoinSnapshot(payload: JSONObject, data: [UInt8]?, labID: String) {
        guard let localUser = self.localUser,
            let memberDicts = payload["members"] as? [JSONObject],
            let notebookObj = payload["notebook"] as? JSONObject,
            let notebookEntries = notebookObj["entries"] as? [JSONObject]
        else { Task { await self.stop() }; return }

        let binaryIndices = notebookObj["binary_indices"] as? [Any] ?? []

        self.labID = labID
        if let labObj = payload["lab"] as? JSONObject {
            if let title = labObj["title"] as? String {
                self.labTitle = title
            }
            if let picture = labObj["picture"] as? JSONObject,
               let contentType = picture["content_type"] as? String,
               let offset = picture["offset"] as? Int,
               let length = picture["length"] as? Int,
               let all = data,
               offset >= 0, offset + length <= all.count {
                self.labPictureData = Data(all[offset..<offset + length])
                self.labPictureContentType = contentType
            } else {
                self.labPictureData = nil
                self.labPictureContentType = nil
            }
        }
        members = memberDicts.compactMap(Member.fromJSON)
        remember(LabMembership(labID: labID, user: localUser, role: members.first { $0.user.id == localUser.id }!.role))
        setStatus(.joined(labID: labID))

        var collabState = try! store.fetchCollaborationState()
        if collabState.labID != labID {
            try? store.forgetLabKnowledge()
        }
        collabState.labID = labID
        try! store.save(collabState)

        var snapshot: [NotebookEntry] = []
        for (i, obj) in notebookEntries.enumerated() {
            let bin: [UInt8]? = extractBinary(indices: binaryIndices, at: i, from: data)
            guard let entry = NotebookEntry.fromJSON(obj, binaryData: bin) else {
                continue
            }
            snapshot.append(entry)
        }
        let sessionDicts = (payload["sessions"] as? [JSONObject]) ?? []
        let sessions = sessionDicts.compactMap(Session.fromJSON)
        let customDicts = (payload["custom_instruments"] as? [JSONObject]) ?? []
        let customBundles = customDicts.compactMap(CustomInstrumentBundle.fromJSON)
        let patternDicts = (payload["patterns"] as? [JSONObject]) ?? []
        let patterns = patternDicts.compactMap(PatternSourceRecord.fromWireJSON)
        let noteDicts = (payload["address_notes"] as? [JSONObject]) ?? []
        let notes = noteDicts.compactMap(AddressNoteThread.fromWireJSON)
        let missionDicts = (payload["missions"] as? [JSONObject]) ?? []
        let missions = missionDicts.compactMap(Mission.fromWireJSON)
        let objectChatDicts = (payload["object_chats"] as? [JSONObject]) ?? []
        let objectChats = objectChatDicts.compactMap(ObjectChatThread.fromWireJSON)
        var heldByLab = snapshot.map { LabSubject(.entry, $0.id) }
        heldByLab += sessions.flatMap(\.labSubjects)
        heldByLab += customBundles.map { LabSubject(.definition, $0.def.id) }
        heldByLab += patterns.map { LabSubject(.pattern, $0.id) }
        heldByLab += notes.map { LabSubject(.addressNote, $0.note.id) }
        heldByLab += missions.map { LabSubject(.mission, $0.id) }
        heldByLab += objectChats.flatMap {
            [LabSubject(.objectChat, $0.chat.id)] + $0.messages.map { LabSubject(.objectChatMessage, $0.id) }
        }
        try? store.markKnownToLab(heldByLab)

        onNotebookSnapshot?(snapshot)
        onCustomInstrumentSnapshot?(customBundles, Self.customInstrumentEditors(in: customDicts))
        onPatternSourcesSnapshot?(patterns)
        let held = Set(heldByLab)
        replayedForSubjectsTheLabLacks = Set(
            ((try? store.fetchOutbox()) ?? []).filter { op in
                if case .session = op { return false }
                return !held.contains(op.labSubject)
            }.map(\.opID))
        replayOutbox(knownSessions: Set(sessions.map(\.id))) { onSessionsSnapshot?(sessions) }

        let widgetStateDicts = (payload["widget_states"] as? [JSONObject]) ?? []
        let viewStateDicts = (payload["view_states"] as? [JSONObject]) ?? []
        onWidgetStatesSnapshot?(widgetStateDicts.compactMap(WidgetStateSnapshot.fromWireJSON))

        ingestViewStates(viewStateDicts, labID: labID)

        let widgetPlacementDicts = (payload["widget_placements"] as? [JSONObject]) ?? []
        onWidgetPlacementsSnapshot?(Self.widgetPlacements(of: sessions, from: widgetPlacementDicts))

        onAddressNotesSnapshot?(notes, Set(sessions.map(\.id)))
        onObjectChatsSnapshot?(objectChats)

        let turnsArr = (payload["mission_turns"] as? [JSONObject]) ?? []
        let actionsArr = (payload["mission_actions"] as? [JSONObject]) ?? []
        let findingsArr = (payload["mission_findings"] as? [JSONObject]) ?? []
        let evidenceArr = (payload["mission_evidence"] as? [JSONObject]) ?? []
        let steeringArr = (payload["mission_steering"] as? [JSONObject]) ?? []
        let missionSnapshot = MissionSnapshot(
            missions: missions,
            turns: turnsArr.compactMap(MissionTurn.fromWireJSON),
            actions: actionsArr.compactMap(MissionAction.fromWireJSON),
            findings: findingsArr.compactMap(MissionFinding.fromWireJSON),
            evidence: evidenceArr.compactMap(MissionEvidence.fromWireJSON),
            steering: steeringArr.compactMap(MissionSteer.fromWireJSON)
        )
        onMissionSnapshot?(missionSnapshot)
    }

    private func extractBinary(indices: [Any], at i: Int, from data: [UInt8]?) -> [UInt8]? {
        guard i < indices.count else { return nil }
        guard let idx = indices[i] as? JSONObject,
            let start = idx["start"] as? Int,
            let length = idx["length"] as? Int,
            let data = data,
            start + length <= data.count
        else { return nil }
        return Array(data[start..<start + length])
    }

    private static func widgetPlacements(of sessions: [Session], from entries: [JSONObject]) -> [UUID: [String: [PatternPlacement]]] {
        let instanceIDs = sessions.flatMap(\.instruments).map(\.id)
        var placements = Dictionary(uniqueKeysWithValues: instanceIDs.map { ($0, [String: [PatternPlacement]]()) })
        for entry in entries {
            guard let instanceID = (entry["instance_id"] as? String).flatMap(UUID.init(uuidString:)),
                let widget = entry["widget"] as? String,
                let placementObjs = entry["placements"] as? [[String: Any]]
            else { continue }
            placements[instanceID]?[widget] = [PatternPlacement](wireJSON: placementObjs)
        }
        return placements
    }

    private func handlePortalEvent(_ event: PortalConnection.Event) {
        switch event {
        case .detached:
            Task { await stop() }
        case .notification(let notification):
            handleNotification(
                from: notification.from,
                type: notification.type,
                payload: notification.payload,
                data: notification.data
            )
        }
    }

    private func applyWelcome(_ payload: JSONObject) {
        if let userObj = payload["user"] as? JSONObject, let u = UserInfo.fromJSON(userObj) {
            localUser = u
        }
        if let push = payload["push"] as? JSONObject {
            if let key = push["vapid_public_key"] as? String {
                vapidPublicKey = key
            }
            if let list = push["registered"] as? [String] {
                registeredPushPlatforms = Set(list)
            }
        }
    }

    private func handleNotification(from: String, type: String, payload: JSONObject, data: [UInt8]?) {
        let segs = from.hasPrefix("/") ? from.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init) : []

        if type == "+op", isEchoOfOpAlreadyApplied(payload), !Self.stampsWhatItEchoes(segs) { return }

        switch (type, segs) {
        case ("+update", let s) where s.count == 2 && s[0] == "labs":
            if let title = payload["title"] as? String {
                labTitle = title
            }

        case ("+update", let s) where s.count == 3 && s[0] == "users" && s[2] == "push_subscriptions":
            if let list = payload["registered"] as? [String] {
                registeredPushPlatforms = Set(list)
            }

        case ("+update", let s) where s.count == 3 && s[0] == "labs" && s[2] == "picture":
            if let contentType = payload["content_type"] as? String,
               let bytes = data, !bytes.isEmpty {
                labPictureData = Data(bytes)
                labPictureContentType = contentType
            }

        case ("+add", let s) where s.count == 3 && s[0] == "labs" && s[2] == "members":
            guard let arr = payload["members"] as? [JSONObject] else { return }
            for obj in arr {
                guard let member = Member.fromJSON(obj) else { continue }
                if !members.contains(where: { $0.user.id == member.user.id }) {
                    members.append(member)
                    onMemberAdded?(member)
                }
            }

        case ("+remove", let s) where s.count == 3 && s[0] == "labs" && s[2] == "members":
            guard let ids = payload["user_ids"] as? [String] else { return }
            for userID in ids {
                members.removeAll { $0.user.id == userID }
                onMemberRemoved?(userID)
            }

        case ("+role-changed", let s) where s.count == 3 && s[0] == "labs" && s[2] == "members":
            guard let userID = payload["user_id"] as? String,
                let roleRaw = payload["role"] as? String,
                let role = Member.Role(rawValue: roleRaw),
                let idx = members.firstIndex(where: { $0.user.id == userID })
            else { return }
            members[idx].role = role
            if isSelf(userID), var mine = membership {
                mine.role = role
                remember(mine)
            }
            onMemberRoleChanged?(userID, role)

        case ("+presence", let s) where s.count == 3 && s[0] == "labs" && s[2] == "members":
            guard let changes = payload["changes"] as? [JSONObject] else { return }
            for change in changes {
                guard let userID = change["user_id"] as? String,
                    let presenceRaw = change["presence"] as? String,
                    let presence = Member.Presence(rawValue: presenceRaw),
                    let lastSeen = change["last_seen_at"] as? String,
                    let idx = members.firstIndex(where: { $0.user.id == userID })
                else { continue }
                members[idx].presence = presence
                members[idx].lastSeenAt = lastSeen
                onMemberPresenceChanged?(userID, presence)
            }

        case ("+op", let s) where s.count == 4 && s[0] == "labs" && s[2] == "notebook" && s[3] == "entries":
            guard let kind = payload["kind"] as? String else { return }
            switch kind {
            case "add":
                if let entryObj = payload["entry"] as? JSONObject,
                   let entry = NotebookEntry.fromJSON(entryObj, binaryData: data) {
                    markKnown(LabSubject(.entry, entry.id))
                    onEntryUpserted?(entry)
                }
            case "update":
                if let entryObj = payload["entry"] as? JSONObject,
                   let entry = NotebookEntry.fromJSON(entryObj, binaryData: nil) {
                    markKnown(LabSubject(.entry, entry.id))
                    onEntryUpserted?(entry)
                }
            case "remove":
                if let idStr = payload["entry_id"] as? String,
                   let id = UUID(uuidString: idStr) {
                    markKnown(LabSubject(.entry, id))
                    onEntryRemoved?(id)
                }
            case "reorder":
                if let idStr = payload["entry_id"] as? String,
                   let id = UUID(uuidString: idStr),
                   let position = (payload["position"] as? Double)
                       ?? (payload["position"] as? NSNumber)?.doubleValue {
                    onEntryRepositioned?(id, position)
                }
            default:
                return
            }

        case ("+op-ack", _):
            guard let idStr = payload["op_id"] as? String,
                let opID = UUID(uuidString: idStr) else { return }
            settleOutboxOp(opID: opID)
            replayedOpIDs.remove(opID)
            if replayedForSubjectsTheLabLacks.remove(opID) != nil, replayedForSubjectsTheLabLacks.isEmpty {
                resyncWithLab()
            }
            if let op = opsOverridingJoinSnapshot.removeValue(forKey: opID) {
                apply(op)
            }

        case ("+op-rejected", _):
            handleOpRejected(payload)

        case ("+op", let s) where s.count == 3 && s[0] == "labs" && s[2] == "custom-instruments":
            guard let op = CustomInstrumentOp.fromJSON(payload) else { return }
            markKnown(QueuedOp.customInstrument(op).labSubject)
            let editor = ((payload["bundle"] as? JSONObject)?["changed_by"] as? JSONObject).flatMap(UserInfo.fromJSON)
            onCustomInstrumentOpReceived?(op, editor.flatMap { $0.id == localUser?.id ? nil : $0 })

        case ("+op", let s) where s.count == 3 && s[0] == "labs" && s[2] == "patterns":
            guard let op = PatternSourceOp.fromJSON(payload) else { return }
            markKnown(QueuedOp.pattern(op).labSubject)
            onPatternSourceOpReceived?(op)

        case ("+op", let s) where s.count == 3 && s[0] == "labs" && s[2] == "missions":
            guard let op = MissionOp.fromJSON(payload) else { return }
            markKnown(QueuedOp.mission(op).labSubject)
            onMissionOpReceived?(op)

        case ("+op", let s) where s.count == 3 && s[0] == "labs" && s[2] == "address-notes":
            guard let op = AddressNoteOp.fromJSON(payload) else { return }
            markKnown(QueuedOp.addressNote(op).labSubject)
            onAddressNoteOpReceived?(op)

        case ("+op", let s) where s.count == 3 && s[0] == "labs" && s[2] == "object-chats":
            guard let op = ObjectChatOp.fromJSON(payload) else { return }
            markKnown(QueuedOp.objectChat(op).labSubject)
            settleOutboxOp(opID: op.opID)
            onObjectChatOpReceived?(op)

        case ("+op", let s) where s.count == 4 && s[0] == "labs" && s[2] == "sessions":
            guard let sessionID = UUID(uuidString: s[3]) else { return }
            applySessionOp(sessionID: sessionID, payload: payload)

        case ("+eval", let s)
            where s.count == 7 && s[0] == "labs" && s[2] == "sessions" && s[4] == "repl" && s[5] == "cells":
            guard let sessionID = UUID(uuidString: s[3]),
                let cellID = UUID(uuidString: s[6]),
                let code = payload["code"] as? String,
                let language = (payload["language"] as? String).flatMap(REPLLanguage.init(rawValue:))
            else { return }
            onSessionReplEvalRequested?(sessionID, code, language, cellID)

        case ("+enable", let s)
            where s.count == 6 && s[0] == "labs" && s[2] == "sessions" && s[4] == "instruments":
            guard let sessionID = UUID(uuidString: s[3]),
                let instanceID = UUID(uuidString: s[5])
            else { return }
            onSessionInstrumentSetStateRequested?(sessionID, instanceID, .enabled)

        case ("+disable", let s)
            where s.count == 6 && s[0] == "labs" && s[2] == "sessions" && s[4] == "instruments":
            guard let sessionID = UUID(uuidString: s[3]),
                let instanceID = UUID(uuidString: s[5])
            else { return }
            onSessionInstrumentSetStateRequested?(sessionID, instanceID, .disabled)

        case ("+remove", let s)
            where s.count == 6 && s[0] == "labs" && s[2] == "sessions" && s[4] == "instruments":
            guard let sessionID = UUID(uuidString: s[3]),
                let instanceID = UUID(uuidString: s[5])
            else { return }
            onSessionInstrumentRemoveRequested?(sessionID, instanceID)

        case ("+add", let s)
            where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "instruments":
            guard let sessionID = UUID(uuidString: s[3]),
                let kindRaw = payload["kind"] as? String,
                let kind = InstrumentKind(rawValue: kindRaw),
                let sourceIdentifier = payload["source_identifier"] as? String,
                let configB64 = payload["config_json"] as? String,
                let configJSON = Data(base64Encoded: configB64)
            else { return }
            onSessionInstrumentAddRequested?(sessionID, kind, sourceIdentifier, configJSON)

        case ("+update-config", let s)
            where s.count == 6 && s[0] == "labs" && s[2] == "sessions" && s[4] == "instruments":
            guard let sessionID = UUID(uuidString: s[3]),
                let instanceID = UUID(uuidString: s[5]),
                let configB64 = payload["config_json"] as? String,
                let configJSON = Data(base64Encoded: configB64)
            else { return }
            onSessionInstrumentUpdateConfigRequested?(sessionID, instanceID, configJSON)

        case ("+event", let s)
            where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "events":
            guard let sessionID = UUID(uuidString: s[3]),
                let event = RuntimeEvent.fromWireJSON(payload)
            else { return }
            onSessionEventReceived?(sessionID, event)

        case ("+event-update", let s)
            where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "events":
            guard let sessionID = UUID(uuidString: s[3]),
                let event = RuntimeEvent.fromWireJSON(payload)
            else { return }
            onSessionEventUpdated?(sessionID, event)

        case ("+widget-update", let s)
            where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "widget-updates":
            guard let sessionID = UUID(uuidString: s[3]),
                let update = WidgetUpdate.fromWireJSON(payload)
            else { return }
            onSessionWidgetUpdateReceived?(sessionID, update)

        case ("+set", let s) where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "view-states":
            guard let sessionID = UUID(uuidString: s[3]) else { return }
            receiveViewState(payload, data: data, sessionID: sessionID, labID: s[1])

        case ("+event", let s) where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "view-events":
            guard let sessionID = UUID(uuidString: s[3]), let target = Self.viewTarget(of: payload) else { return }
            let event = WidgetViewPayload(value: payload["value"], data: data.map { SharedBytes(copying: $0) })
            onSessionViewEventReceived?(sessionID, target.instanceID, target.widget, event)

        case ("+message", let s) where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "view-messages":
            guard let sessionID = UUID(uuidString: s[3]),
                let target = Self.viewTarget(of: payload),
                let sender = (payload["from"] as? JSONObject).flatMap(UserInfo.fromJSON)
            else { return }
            let message = WidgetViewPayload(value: payload["value"], data: data.map { SharedBytes(copying: $0) })
            onSessionViewMessageReceived?(sessionID, target.instanceID, target.widget, message, sender)

        case ("+widget-action", let s)
            where s.count == 5 && s[0] == "labs" && s[2] == "sessions" && s[4] == "widget-actions":
            guard let sessionID = UUID(uuidString: s[3]),
                let instanceStr = payload["instance_id"] as? String,
                let instanceID = UUID(uuidString: instanceStr),
                let widget = payload["widget"] as? String,
                let action = payload["action"] as? String
            else { return }
            onSessionWidgetActionRequested?(sessionID, instanceID, widget, action, payload["item"] as? String)

        default:
            break
        }
    }

    func handleOpRejected(_ payload: JSONObject) {
        guard let opID = (payload["op_id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let reason = (payload["reason"] as? String) ?? "rejected"
        opsOverridingJoinSnapshot.removeValue(forKey: opID)
        replayedForSubjectsTheLabLacks.remove(opID)
        guard let rejected = try? store.fetchOutboxOp(opID: opID) else { return }
        _ = try? store.removeOutboxOp(opID: opID)
        if reason == Self.patternNameTaken, case .pattern(.upsert(let upsert)) = rejected {
            onPatternSourceNameTaken?(upsert.record)
        } else {
            if announceRemovalInLab(of: rejected, because: reason) {
                markKnown(rejected.labSubject)
                return resyncWithLab()
            }
            if case .objectChat(let op) = rejected, case .messageAppend(let message) = op.change {
                onObjectChatMessageRefused?(message, reason)
            } else if case .objectChat(let op) = rejected {
                onObjectChatOpRefused?(op, reason)
                markKnown(QueuedOp.objectChat(op).labSubject)
            } else {
                markKnown(rejected.labSubject)
            }
            onOpRejected?(reason)
            resyncWithLab()
        }
    }

    private func announceRemovalInLab(of rejected: QueuedOp, because reason: String) -> Bool {
        switch rejected {
        case .mission(let op) where reason.hasSuffix(": the mission was removed"):
            onMissionRemovedInLab?(op.missionID)
        case .customInstrument(.upsert(let upsert)) where reason == "upsert: the instrument was removed":
            try? store.removeOutboxOps(family: CustomInstrumentOp.outboxFamily, subject: upsert.bundle.def.id)
            onCustomInstrumentRemovedInLab?(upsert.bundle.def.id)
        case .pattern(.upsert(let upsert)) where reason == "upsert: the pattern was removed":
            try? store.removeOutboxOps(family: PatternSourceOp.outboxFamily, subject: upsert.record.id)
            onPatternRemovedInLab?(upsert.record.id)
        default:
            return false
        }
        return true
    }

    private static func stampsWhatItEchoes(_ segs: [String]) -> Bool {
        segs.count >= 3 && ["notebook", "missions", "address-notes", "object-chats"].contains(segs[2])
    }

    private func isEchoOfOpAlreadyApplied(_ payload: JSONObject) -> Bool {
        guard let idStr = payload["op_id"] as? String,
            let opID = UUID(uuidString: idStr),
            settleOutboxOp(opID: opID)
        else { return false }
        return replayedOpIDs.remove(opID) == nil
    }

    @discardableResult
    private func settleOutboxOp(opID: UUID) -> Bool {
        if let settled = try? store.fetchOutboxOp(opID: opID) {
            markKnown(settled.labSubject)
        }
        return (try? store.removeOutboxOp(opID: opID)) == true
    }

    private func resyncWithLab() {
        guard case .joined(let labID) = status else { return }
        sendRequest(to: "/labs/\(labID)", type: ".snapshot") { [weak self] result in
            guard case .success(let reply) = result else { return }
            self?.ingestJoinSnapshot(payload: reply.payload, data: reply.data, labID: labID)
        }
    }

    private func markKnown(_ subject: LabSubject) {
        try? store.markKnownToLab([subject])
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        _statusChanges.yield(newStatus)
    }
}
