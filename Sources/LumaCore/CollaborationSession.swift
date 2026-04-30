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
        public enum Role: String, Sendable { case owner, member }
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
        public var driver: UserInfo
        public let createdAt: String
        public var lastSeenAt: String
        public var modules: [ProcessModule]
        public var replCells: [REPLCell]
        public var instruments: [InstrumentInstance]
        public var insights: [AddressInsight]
        public var captures: [ITraceCaptureRecord]

        public init(
            id: UUID,
            host: UserInfo,
            deviceID: String,
            deviceName: String,
            pid: UInt,
            processName: String,
            phase: Phase,
            driver: UserInfo,
            createdAt: String,
            lastSeenAt: String,
            modules: [ProcessModule],
            replCells: [REPLCell] = [],
            instruments: [InstrumentInstance] = [],
            insights: [AddressInsight] = [],
            captures: [ITraceCaptureRecord] = []
        ) {
            self.id = id
            self.host = host
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.pid = pid
            self.processName = processName
            self.phase = phase
            self.driver = driver
            self.createdAt = createdAt
            self.lastSeenAt = lastSeenAt
            self.modules = modules
            self.replCells = replCells
            self.instruments = instruments
            self.insights = insights
            self.captures = captures
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

            let driver: UserInfo
            if let driverObj = obj["driver"] as? [String: Any],
               let parsed = UserInfo.fromJSON(driverObj) {
                driver = parsed
            } else {
                driver = host
            }

            let moduleObjs = (obj["modules"] as? [[String: Any]]) ?? []
            let modules = moduleObjs.compactMap(ProcessModule.fromJSON)

            let cellObjs = (obj["repl_cells"] as? [[String: Any]]) ?? []
            let cells = cellObjs.compactMap(REPLCell.fromWireJSON)

            let instrumentObjs = (obj["instruments"] as? [[String: Any]]) ?? []
            let instruments = instrumentObjs.compactMap(InstrumentInstance.fromWireJSON)

            let insightObjs = (obj["insights"] as? [[String: Any]]) ?? []
            let insights = insightObjs.compactMap(AddressInsight.fromWireJSON)

            let captureObjs = (obj["captures"] as? [[String: Any]]) ?? []
            let captures = captureObjs.compactMap(ITraceCaptureRecord.fromWireJSON)

            return Session(
                id: id,
                host: host,
                deviceID: deviceID,
                deviceName: deviceName,
                pid: pid,
                processName: processName,
                phase: phase,
                driver: driver,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                modules: modules,
                replCells: cells,
                instruments: instruments,
                insights: insights,
                captures: captures
            )
        }
    }

    public struct ChatMessage: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let text: String
        public let sender: UserInfo
        public let isLocal: Bool
        public let timestamp: Date

        public init(id: UUID = UUID(), text: String, sender: UserInfo, isLocal: Bool, timestamp: Date = .now) {
            self.id = id
            self.text = text
            self.sender = sender
            self.isLocal = isLocal
            self.timestamp = timestamp
        }

        public static func fromJSON(_ obj: [String: Any], localUser: UserInfo) -> ChatMessage? {
            guard let text = obj["text"] as? String,
                let senderObj = obj["user"] as? [String: Any],
                let sender = UserInfo.fromJSON(senderObj)
            else { return nil }
            return ChatMessage(text: text, sender: sender, isLocal: sender.id == localUser.id)
        }
    }

    private let deviceManager: DeviceManager
    private let store: ProjectStore
    private let portalAddress: String
    private let portalCertificate: String

    private(set) public var status: Status = .disconnected
    private(set) public var labID: String?
    private(set) public var labTitle: String?
    private(set) public var labPictureData: Data?
    private(set) public var labPictureContentType: String?
    private(set) public var localUser: UserInfo?
    private(set) public var members: [Member] = []
    private(set) public var chatMessages: [ChatMessage] = []
    private(set) public var vapidPublicKey: String?
    private(set) public var registeredPushPlatforms: Set<String> = []
    public var isHost = false

    public var isOwner: Bool {
        guard let localUser else { return false }
        return members.contains { $0.user.id == localUser.id && $0.role == .owner }
    }

    /// True when the given user id belongs to the currently signed-in user.
    public func isSelf(_ userID: String) -> Bool {
        userID == localUser?.id
    }

    private var portalDevice: Device?
    private var portalBusTask: Task<Void, Never>?

    private let _statusChanges = AsyncEventSource<Status>()
    public var statusChanges: AsyncStream<Status> { _statusChanges.makeStream() }

    public var onNotebookSnapshot: (([NotebookEntry]) -> Void)?
    public var onEntryUpserted: ((NotebookEntry) -> Void)?
    public var onEntryRemoved: ((UUID) -> Void)?
    public var onEntryRepositioned: ((UUID, Double) -> Void)?
    public var onOpRejected: ((UUID, String) -> Void)?
    public var onMemberAdded: ((Member) -> Void)?
    public var onMemberRemoved: ((String) -> Void)?
    public var onMemberRoleChanged: ((String, Member.Role) -> Void)?
    public var onMemberPresenceChanged: ((String, Member.Presence) -> Void)?
    public var onSessionsSnapshot: (([Session]) -> Void)?
    public var onSessionAdded: ((Session) -> Void)?
    public var onSessionPhaseChanged: ((UUID, Session.Phase, String?) -> Void)?
    public var onSessionModulesUpdated: ((UUID, [ProcessModule]) -> Void)?
    public var onSessionHostChanged: ((UUID, UserInfo, String, String, UInt, String) -> Void)?
    public var onSessionDriverChanged: ((UUID, UserInfo) -> Void)?
    public var onSessionReplCellAdded: ((UUID, REPLCell) -> Void)?
    public var onSessionReplEvalRequested: ((UUID, String, UUID) -> Void)?
    public var onSessionInstrumentAdded: ((UUID, InstrumentInstance) -> Void)?
    public var onSessionInstrumentUpdated: ((UUID, InstrumentInstance) -> Void)?
    public var onSessionInstrumentRemoved: ((UUID, UUID) -> Void)?
    public var onSessionInstrumentSetStateRequested: ((UUID, UUID, InstrumentState) -> Void)?
    public var onSessionInstrumentRemoveRequested: ((UUID, UUID) -> Void)?
    public var onSessionInstrumentAddRequested: ((UUID, InstrumentKind, String, Data) -> Void)?
    public var onSessionInstrumentUpdateConfigRequested: ((UUID, UUID, Data) -> Void)?
    public var onSessionInsightAdded: ((UUID, AddressInsight) -> Void)?
    public var onSessionInsightRemoved: ((UUID, UUID) -> Void)?
    public var onSessionCaptureAdded: ((UUID, ITraceCaptureRecord) -> Void)?
    public var onSessionCaptureRemoved: ((UUID, UUID) -> Void)?
    public var onSessionEventReceived: ((UUID, RuntimeEvent) -> Void)?
    public var onReplEvalTimedOut: ((UUID) -> Void)?
    public var onSessionRemoved: ((UUID) -> Void)?
    public var onSessionOpRejected: ((UUID, String) -> Void)?
    public var onChatMessageReceived: ((ChatMessage) -> Void)?
    public var onAuthRejected: ((AuthFailure) async -> Void)?

    private var nextRequestId = 0
    private var pendingRequests: [String: (Result<JSONObject, AuthFailure>) -> Void] = [:]

    public init(
        deviceManager: DeviceManager,
        store: ProjectStore,
        portalAddress: String,
        portalCertificate: String
    ) {
        self.deviceManager = deviceManager
        self.store = store
        self.portalAddress = portalAddress
        self.portalCertificate = portalCertificate
    }

    public func start(token: String, existingLabID: String?) async {
        guard case .disconnected = status else { return }
        setStatus(.connecting)

        do {
            let device = try await deviceManager.addRemoteDevice(
                address: portalAddress,
                certificate: portalCertificate,
                origin: nil,
                token: token,
                keepaliveInterval: nil
            )
            portalDevice = device

            let busEvents = device.bus.events
            portalBusTask?.cancel()
            portalBusTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await event in busEvents {
                    await self.handleBusEvent(event)
                }
            }

            try await device.bus.attach()

            if let existingLabID {
                isHost = false
                joinLab(labID: existingLabID)
            } else {
                isHost = true
                createLab()
            }
        } catch {
            if let failure = AuthFailure.fromError(error), failure.isAuthRejection {
                setStatus(.error(message: failure.message))
                await onAuthRejected?(failure)
            } else {
                setStatus(.error(message: String(describing: error)))
            }
        }
    }

    public func stop() async {
        try? await deviceManager.removeRemoteDevice(address: portalAddress)

        portalBusTask?.cancel()
        portalBusTask = nil
        portalDevice = nil

        setStatus(.disconnected)
        labID = nil
        labTitle = nil
        labPictureData = nil
        labPictureContentType = nil
        localUser = nil
        members = []
        chatMessages = []
        vapidPublicKey = nil
        registeredPushPlatforms = []
        pendingRequests.removeAll()
    }

    // MARK: - Sending

    private func sendRequest(
        to path: String,
        type: String,
        payload: JSONObject = [:],
        data: [UInt8]? = nil,
        onResult: @escaping (Result<JSONObject, AuthFailure>) -> Void
    ) {
        guard let device = portalDevice else { return }
        nextRequestId += 1
        let id = "r\(nextRequestId)"
        pendingRequests[id] = onResult
        var msg: JSONObject = ["to": path, "type": type, "id": id]
        if !payload.isEmpty { msg["payload"] = payload }
        device.bus.post(msg, data: data)
    }

    private func sendNotification(
        to path: String,
        type: String,
        payload: JSONObject,
        data: [UInt8]? = nil
    ) {
        guard let device = portalDevice else { return }
        var msg: JSONObject = ["to": path, "type": type]
        if !payload.isEmpty { msg["payload"] = payload }
        device.bus.post(msg, data: data)
    }

    public func sendChat(_ text: String) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/chat/messages",
            type: "+add",
            payload: ["messages": [["text": text]]]
        )
    }

    /// True once this project has ever joined or created a lab. Local-only
    /// projects skip the outbox entirely so they never touch that table.
    public var isCollaborative: Bool {
        (try? store.fetchCollaborationState())?.labID != nil
    }

    public func enqueueAdd(_ entry: NotebookEntry) {
        guard isCollaborative else { return }
        let op = NotebookOp.add(.init(entry: entry))
        try? store.saveOutboxOp(op)
        sendOpIfJoined(op)
    }

    public func enqueueUpdate(
        entryID: UUID,
        title: String? = nil,
        details: String? = nil,
        processName: String? = nil
    ) {
        guard isCollaborative else { return }
        let op = NotebookOp.update(.init(
            entryID: entryID,
            title: title,
            details: details,
            processName: processName
        ))
        try? store.saveOutboxOp(op)
        sendOpIfJoined(op)
    }

    public func enqueueRemove(entryID: UUID) {
        guard isCollaborative else { return }
        let op = NotebookOp.remove(.init(entryID: entryID))
        try? store.saveOutboxOp(op)
        sendOpIfJoined(op)
    }

    public func enqueueReorder(entryID: UUID, position: Double) {
        guard isCollaborative else { return }
        let op = NotebookOp.reorder(.init(entryID: entryID, position: position))
        try? store.saveOutboxOp(op)
        sendOpIfJoined(op)
    }

    /// Resend every op still in the outbox. Called after a successful
    /// join/create so unsynced mutations propagate. The server dedupes by
    /// `op_id`, so redundant replays are safe.
    public func replayOutbox() {
        guard case .joined(let labID) = status else { return }
        let notebookOps = (try? store.fetchOutboxOps()) ?? []
        for op in notebookOps {
            sendOpOverWire(op, labID: labID)
        }
        let sessionOps = (try? store.fetchSessionOutboxOps()) ?? []
        for op in sessionOps {
            sendSessionOpOverWire(op, labID: labID)
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
                case .success(let payload):
                    guard let token = payload["token"] as? String,
                        let vapid = payload["vapid_public_key"] as? String
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

    public func enqueueUpdateSessionModules(sessionID: UUID, modules: [ProcessModule]) {
        enqueueSessionOp(.updateModules(.init(
            sessionID: sessionID,
            modules: modules
        )))
    }

    public func enqueueRemoveSession(sessionID: UUID) {
        enqueueSessionOp(.remove(.init(sessionID: sessionID)))
    }

    public func enqueueClaimHost(
        sessionID: UUID,
        deviceID: String,
        deviceName: String,
        pid: UInt,
        processName: String
    ) {
        guard let localUser else { return }
        enqueueSessionOp(.claimHost(.init(
            sessionID: sessionID,
            host: localUser,
            deviceID: deviceID,
            deviceName: deviceName,
            pid: pid,
            processName: processName
        )))
    }

    public func enqueueClaimDriver(sessionID: UUID) {
        guard let localUser else { return }
        enqueueSessionOp(.claimDriver(.init(sessionID: sessionID, driver: localUser)))
    }

    public func enqueueAddReplCell(sessionID: UUID, cell: REPLCell) {
        var wireCell = cell
        wireCell.sessionID = sessionID
        enqueueSessionOp(.addReplCell(.init(sessionID: sessionID, cell: wireCell)))
    }

    public func enqueueAddInstrument(sessionID: UUID, instance: InstrumentInstance) {
        var wireInst = instance
        wireInst.sessionID = sessionID
        enqueueSessionOp(.addInstrument(.init(sessionID: sessionID, instance: wireInst)))
    }

    public func enqueueUpdateInstrument(sessionID: UUID, instance: InstrumentInstance) {
        var wireInst = instance
        wireInst.sessionID = sessionID
        enqueueSessionOp(.updateInstrument(.init(sessionID: sessionID, instance: wireInst)))
    }

    public func enqueueRemoveInstrument(sessionID: UUID, instanceID: UUID) {
        enqueueSessionOp(.removeInstrument(.init(sessionID: sessionID, instanceID: instanceID)))
    }

    public func enqueueAddInsight(sessionID: UUID, insight: AddressInsight) {
        var wireInsight = insight
        wireInsight.sessionID = sessionID
        enqueueSessionOp(.addInsight(.init(sessionID: sessionID, insight: wireInsight)))
    }

    public func enqueueRemoveInsight(sessionID: UUID, insightID: UUID) {
        enqueueSessionOp(.removeInsight(.init(sessionID: sessionID, insightID: insightID)))
    }

    public func enqueueAddCapture(sessionID: UUID, capture: ITraceCaptureRecord) {
        var wireCapture = capture
        wireCapture.sessionID = sessionID
        enqueueSessionOp(.addCapture(.init(sessionID: sessionID, capture: wireCapture)))
    }

    public func enqueueRemoveCapture(sessionID: UUID, captureID: UUID) {
        enqueueSessionOp(.removeCapture(.init(sessionID: sessionID, captureID: captureID)))
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


    public func sendReplEvalRequest(sessionID: UUID, code: String, cellID: UUID) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/repl/cells/\(cellID.uuidString)",
            type: "+eval",
            payload: ["code": code]
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
        try? store.saveSessionOutboxOp(op)
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
                driver: a.host,
                createdAt: a.createdAt,
                lastSeenAt: a.createdAt,
                modules: []
            )
            onSessionAdded?(session)

        case .updatePhase(let u):
            onSessionPhaseChanged?(u.sessionID, u.phase, u.reason)

        case .updateModules(let u):
            onSessionModulesUpdated?(u.sessionID, u.modules)

        case .claimHost(let c):
            onSessionHostChanged?(
                c.sessionID, c.host, c.deviceID, c.deviceName, c.pid, c.processName
            )

        case .claimDriver(let c):
            onSessionDriverChanged?(c.sessionID, c.driver)

        case .addReplCell(let a):
            cancelPendingReplTimeout(cellID: a.cell.id)
            onSessionReplCellAdded?(a.sessionID, a.cell)

        case .addInstrument(let a):
            onSessionInstrumentAdded?(a.sessionID, a.instance)

        case .updateInstrument(let u):
            onSessionInstrumentUpdated?(u.sessionID, u.instance)

        case .removeInstrument(let r):
            onSessionInstrumentRemoved?(r.sessionID, r.instanceID)

        case .addInsight(let a):
            onSessionInsightAdded?(a.sessionID, a.insight)

        case .removeInsight(let r):
            onSessionInsightRemoved?(r.sessionID, r.insightID)

        case .addCapture(let a):
            onSessionCaptureAdded?(a.sessionID, a.capture)

        case .removeCapture(let r):
            onSessionCaptureRemoved?(r.sessionID, r.captureID)

        case .remove(let r):
            onSessionRemoved?(r.sessionID)
        }
        try? store.removeSessionOutboxOp(opID: op.opID)
    }

    // MARK: - Lab Operations

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
            payload: ["title": title, "picture": ["content_type": pictureContentType]],
            data: [UInt8](pictureData)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                guard let labObj = payload["lab"] as? JSONObject,
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
                self.setStatus(.joined(labID: labID))
                let now = ISO8601DateFormatter().string(from: Date())
                self.members = [Member(
                    user: localUser,
                    role: .owner,
                    presence: .online,
                    joinedAt: now,
                    lastSeenAt: now
                )]
                let entries = (try? self.store.fetchNotebookEntries()) ?? []
                let ops: [NotebookOp] = entries.map { .add(.init(entry: $0)) }
                try? self.store.saveOutboxOps(ops)
                self.replayOutbox()
            case .failure(let failure):
                self.setStatus(.error(message: failure.message))
            }
        }
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
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let raw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let contentType = raw.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
            guard Self.allowedAvatarContentTypes.contains(contentType) else { return nil }
            return AvatarBytes(data: data, contentType: contentType)
        } catch {
            return nil
        }
    }

    private func joinLab(labID: String) {
        setStatus(.connecting)
        sendRequest(to: "/labs/\(labID)", type: ".join") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                self.ingestJoinSnapshot(payload: payload, labID: labID)
                self.replayOutbox()
            case .failure(let failure):
                self.setStatus(.error(message: failure.message))
            }
        }
    }

    private func ingestJoinSnapshot(payload: JSONObject, labID: String) {
        guard let localUser = self.localUser,
            let memberDicts = payload["members"] as? [JSONObject],
            let chatObj = payload["chat"] as? JSONObject,
            let chatMsgs = chatObj["messages"] as? [JSONObject],
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
               let all = lastMessageData,
               offset >= 0, offset + length <= all.count {
                self.labPictureData = Data(all[offset..<offset + length])
                self.labPictureContentType = contentType
            } else {
                self.labPictureData = nil
                self.labPictureContentType = nil
            }
        }
        setStatus(.joined(labID: labID))
        members = memberDicts.compactMap(Member.fromJSON)
        chatMessages = chatMsgs.compactMap { ChatMessage.fromJSON($0, localUser: localUser) }

        var collabState = try! store.fetchCollaborationState()
        collabState.labID = labID
        try! store.save(collabState)

        // Note: .join response data (binary blob) is fetched separately via
        // the last-data on the message; see handleBusEvent.
        var snapshot: [NotebookEntry] = []
        for (i, obj) in notebookEntries.enumerated() {
            let bin: [UInt8]? = extractBinary(indices: binaryIndices, at: i, from: lastMessageData)
            guard let entry = NotebookEntry.fromJSON(obj, binaryData: bin) else {
                continue
            }
            snapshot.append(entry)
        }
        onNotebookSnapshot?(snapshot)

        let sessionDicts = (payload["sessions"] as? [JSONObject]) ?? []
        let sessions = sessionDicts.compactMap(Session.fromJSON)
        onSessionsSnapshot?(sessions)
    }

    private var lastMessageData: [UInt8]? = nil

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

    // MARK: - Bus Event Handling

    private func handleBusEvent(_ event: Bus.Event) async {
        switch event {
        case .detached:
            await stop()

        case .message(message: let anyValue, let data):
            guard let dict = anyValue as? JSONObject,
                let type = dict["type"] as? String
            else { await stop(); return }

            let id = dict["id"] as? String
            let payload = (dict["payload"] as? JSONObject) ?? [:]
            let errorObj = dict["error"] as? JSONObject

            if type == "+result" || type == "+error" {
                guard let id, let cont = pendingRequests.removeValue(forKey: id) else { return }
                if type == "+result" {
                    self.lastMessageData = data
                    cont(.success(payload))
                    self.lastMessageData = nil
                } else {
                    let code = errorObj?["code"] as? String ?? "unknown"
                    let msg = errorObj?["message"] as? String ?? "request failed"
                    cont(.failure(AuthFailure(domain: "portal", code: code, message: msg)))
                }
                return
            }

            guard let from = dict["from"] as? String else { return }
            lastMessageData = data
            handleNotification(from: from, type: type, payload: payload, data: data)
            lastMessageData = nil
        }
    }

    private func handleNotification(from: String, type: String, payload: JSONObject, data: [UInt8]?) {
        let segs = from.hasPrefix("/") ? from.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init) : []

        switch (type, segs) {
        case ("+welcome", ["session"]):
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
            let opID = (payload["op_id"] as? String).flatMap(UUID.init(uuidString:))
            switch kind {
            case "add":
                if let entryObj = payload["entry"] as? JSONObject,
                   let entry = NotebookEntry.fromJSON(entryObj, binaryData: data) {
                    onEntryUpserted?(entry)
                }
            case "update":
                if let entryObj = payload["entry"] as? JSONObject,
                   let entry = NotebookEntry.fromJSON(entryObj, binaryData: nil) {
                    onEntryUpserted?(entry)
                }
            case "remove":
                if let idStr = payload["entry_id"] as? String,
                   let id = UUID(uuidString: idStr) {
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
            // Successful echo — remove any matching outbox entry.
            if let opID {
                try? store.removeOutboxOp(opID: opID)
            }

        case ("+op-rejected", let s) where s.count == 4 && s[0] == "labs" && s[2] == "notebook" && s[3] == "entries":
            guard let idStr = payload["op_id"] as? String,
                let opID = UUID(uuidString: idStr) else { return }
            let reason = (payload["reason"] as? String) ?? "rejected"
            try? store.removeOutboxOp(opID: opID)
            onOpRejected?(opID, reason)

        case ("+op", let s) where s.count == 4 && s[0] == "labs" && s[2] == "sessions":
            guard let sessionID = UUID(uuidString: s[3]) else { return }
            applySessionOp(sessionID: sessionID, payload: payload)

        case ("+op-rejected", let s) where s.count == 4 && s[0] == "labs" && s[2] == "sessions":
            guard let idStr = payload["op_id"] as? String,
                let opID = UUID(uuidString: idStr) else { return }
            let reason = (payload["reason"] as? String) ?? "rejected"
            try? store.removeSessionOutboxOp(opID: opID)
            onSessionOpRejected?(opID, reason)

        case ("+eval", let s)
            where s.count == 7 && s[0] == "labs" && s[2] == "sessions" && s[4] == "repl" && s[5] == "cells":
            guard let sessionID = UUID(uuidString: s[3]),
                let cellID = UUID(uuidString: s[6]),
                let code = payload["code"] as? String
            else { return }
            onSessionReplEvalRequested?(sessionID, code, cellID)

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

        case ("+add", let s) where s.count == 4 && s[0] == "labs" && s[2] == "chat" && s[3] == "messages":
            guard let localUser, let msgs = payload["messages"] as? [JSONObject] else { return }
            for m in msgs {
                if let message = ChatMessage.fromJSON(m, localUser: localUser) {
                    chatMessages.append(message)
                    onChatMessageReceived?(message)
                }
            }

        default:
            break
        }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        _statusChanges.yield(newStatus)
    }
}
