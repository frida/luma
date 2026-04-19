import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class CollaborationSession {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case joined(labID: String)
        case error(message: String)
    }

    public struct UserInfo: Identifiable, Hashable, Sendable {
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
        public let role: Role
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
    private(set) public var localUser: UserInfo?
    private(set) public var members: [Member] = []
    private(set) public var chatMessages: [ChatMessage] = []
    private(set) public var vapidPublicKey: String?
    public var isHost = false

    public var isOwner: Bool {
        guard let localUser else { return false }
        return members.contains { $0.user.id == localUser.id && $0.role == .owner }
    }

    private var portalDevice: Device?
    private var portalBusTask: Task<Void, Never>?

    private let _statusChanges = AsyncEventSource<Status>()
    public var statusChanges: AsyncStream<Status> { _statusChanges.makeStream() }

    public var onNotebookEntriesReceived: (([NotebookEntry]) -> Void)?
    public var onNotebookEntryAdded: ((NotebookEntry) -> Void)?
    public var onNotebookEntryUpdated: ((UUID, JSONObject) -> Void)?
    public var onNotebookEntryDeleted: ((UUID) -> Void)?
    public var onEntriesReordered: (([UUID]) -> Void)?
    public var onMemberAdded: ((Member) -> Void)?
    public var onMemberRemoved: ((String) -> Void)?
    public var onMemberPresenceChanged: ((String, Member.Presence) -> Void)?
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
        localUser = nil
        members = []
        chatMessages = []
        vapidPublicKey = nil
        pendingRequests.removeAll()
    }

    // MARK: - Sending

    private func sendRequest(
        from path: String,
        type: String,
        payload: JSONObject = [:],
        data: [UInt8]? = nil,
        onResult: @escaping (Result<JSONObject, AuthFailure>) -> Void
    ) {
        guard let device = portalDevice else { return }
        nextRequestId += 1
        let id = "r\(nextRequestId)"
        pendingRequests[id] = onResult
        var msg: JSONObject = ["from": path, "type": type, "id": id]
        if !payload.isEmpty { msg["payload"] = payload }
        device.bus.post(msg, data: data)
    }

    private func sendNotification(
        from path: String,
        type: String,
        payload: JSONObject,
        data: [UInt8]? = nil
    ) {
        guard let device = portalDevice else { return }
        var msg: JSONObject = ["from": path, "type": type]
        if !payload.isEmpty { msg["payload"] = payload }
        device.bus.post(msg, data: data)
    }

    public func sendChat(_ text: String) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            from: "/labs/\(labID)/chat/messages",
            type: "+add",
            payload: ["messages": [["text": text]]]
        )
    }

    public func notifyEntryAdded(_ entry: NotebookEntry) {
        guard case .joined(let labID) = status else { return }
        let bin = entry.binaryData.map { [UInt8]($0) }
        var payload: JSONObject = ["entries": [entry.toJSON()]]
        if let bin {
            payload["binary_indices"] = [["start": 0, "length": bin.count] as JSONObject]
        } else {
            payload["binary_indices"] = [NSNull()]
        }
        sendNotification(
            from: "/labs/\(labID)/notebook/entries",
            type: "+add",
            payload: payload,
            data: bin,
        )
    }

    public func notifyEntryUpdated(_ entry: NotebookEntry) {
        guard case .joined(let labID) = status else { return }
        let full = entry.toJSON()
        var changes: JSONObject = [:]
        for k in ["title", "details", "js_value", "process_name"] where full[k] != nil {
            changes[k] = full[k]
        }
        sendNotification(
            from: "/labs/\(labID)/notebook/entries",
            type: "+update",
            payload: ["updates": [["entry_id": entry.id.uuidString, "changes": changes]]]
        )
    }

    public func notifyEntryDeleted(id: UUID) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            from: "/labs/\(labID)/notebook/entries",
            type: "+remove",
            payload: ["entry_ids": [id.uuidString]]
        )
    }

    public func reorderEntries(_ order: [UUID]) {
        guard case .joined(let labID) = status else { return }
        sendNotification(
            from: "/labs/\(labID)/notebook/entries",
            type: "+reorder",
            payload: ["order": order.map { $0.uuidString }]
        )
    }

    public func registerPushSubscriptions(_ subs: [JSONObject]) {
        guard let localUser else { return }
        sendNotification(
            from: "/users/\(localUser.id)/push_subscriptions",
            type: "+add",
            payload: ["subscriptions": subs]
        )
    }

    public func unregisterPushSubscriptions(_ subs: [JSONObject]) {
        guard let localUser else { return }
        sendNotification(
            from: "/users/\(localUser.id)/push_subscriptions",
            type: "+remove",
            payload: ["subscriptions": subs]
        )
    }

    public func removeMembers(_ userIDs: [String]) async {
        guard case .joined(let labID) = status else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sendRequest(
                from: "/labs/\(labID)/members",
                type: ".remove",
                payload: ["user_ids": userIDs]
            ) { _ in cont.resume() }
        }
    }

    // MARK: - Lab Operations

    private func createLab() {
        setStatus(.connecting)
        sendRequest(from: "/labs", type: ".create") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                guard let labObj = payload["lab"] as? JSONObject,
                    let labID = labObj["id"] as? String,
                    let localUser = self.localUser
                else { Task { await self.stop() }; return }
                self.labID = labID
                self.setStatus(.joined(labID: labID))
                let now = ISO8601DateFormatter().string(from: Date())
                self.members = [Member(
                    user: localUser,
                    role: .owner,
                    presence: .online,
                    joinedAt: now,
                    lastSeenAt: now
                )]
                var collabState = try! self.store.fetchCollaborationState()
                collabState.labID = labID
                try! self.store.save(collabState)
                let entries = try! self.store.fetchNotebookEntries()
                for entry in entries {
                    self.notifyEntryAdded(entry)
                }
            case .failure(let failure):
                self.setStatus(.error(message: failure.message))
            }
        }
    }

    private func joinLab(labID: String) {
        setStatus(.connecting)
        sendRequest(from: "/labs/\(labID)", type: ".join") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                self.ingestJoinSnapshot(payload: payload, labID: labID)
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
        onNotebookEntriesReceived?(snapshot)
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
            if let push = payload["push"] as? JSONObject,
                let key = push["vapid_public_key"] as? String {
                vapidPublicKey = key
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

        case ("+add", let s) where s.count == 4 && s[0] == "labs" && s[2] == "notebook" && s[3] == "entries":
            guard let entries = payload["entries"] as? [JSONObject] else { return }
            let binaryIndices = payload["binary_indices"] as? [Any] ?? []
            for (i, obj) in entries.enumerated() {
                let bin = extractBinary(indices: binaryIndices, at: i, from: data)
                guard let entry = NotebookEntry.fromJSON(obj, binaryData: bin) else { continue }
                onNotebookEntryAdded?(entry)
            }

        case ("+update", let s) where s.count == 4 && s[0] == "labs" && s[2] == "notebook" && s[3] == "entries":
            guard let updates = payload["updates"] as? [JSONObject] else { return }
            for u in updates {
                guard let entryIdStr = u["entry_id"] as? String,
                    let entryId = UUID(uuidString: entryIdStr),
                    let changes = u["changes"] as? JSONObject
                else { continue }
                onNotebookEntryUpdated?(entryId, changes)
            }

        case ("+remove", let s) where s.count == 4 && s[0] == "labs" && s[2] == "notebook" && s[3] == "entries":
            guard let ids = payload["entry_ids"] as? [String] else { return }
            for idStr in ids {
                if let id = UUID(uuidString: idStr) {
                    onNotebookEntryDeleted?(id)
                }
            }

        case ("+reorder", let s) where s.count == 4 && s[0] == "labs" && s[2] == "notebook" && s[3] == "entries":
            guard let rawOrder = payload["order"] as? [String] else { return }
            let order = rawOrder.compactMap(UUID.init(uuidString:))
            if order.count == rawOrder.count {
                onEntriesReordered?(order)
            }

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
