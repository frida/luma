import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class CollaborationSession {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case joined(roomID: String)
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
            let avatarURL = (obj["avatar_url"] as? String).flatMap(URL.init(string:))
            return UserInfo(id: id, name: name, avatarURL: avatarURL)
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
    private(set) public var roomID: String?
    private(set) public var localUser: UserInfo?
    private(set) public var participants: [UserInfo] = []
    private(set) public var chatMessages: [ChatMessage] = []
    public var isHost = false

    private var portalDevice: Device?
    private var portalBusTask: Task<Void, Never>?

    private let _statusChanges = AsyncEventSource<Status>()
    public var statusChanges: AsyncStream<Status> { _statusChanges.makeStream() }

    public var onNotebookEntriesReceived: (([NotebookEntry]) -> Void)?
    public var onNotebookEntryAdded: ((NotebookEntry) -> Void)?
    public var onNotebookEntryUpdated: ((NotebookEntry) -> Void)?
    public var onNotebookEntryDeleted: ((UUID) -> Void)?
    public var onEntriesReordered: (([UUID]) -> Void)?
    public var onParticipantJoined: ((UserInfo) -> Void)?
    public var onParticipantLeft: ((String) -> Void)?
    public var onChatMessageReceived: ((ChatMessage) -> Void)?

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

    public func start(token: String, existingRoomID: String?) async {
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

            if let existingRoomID {
                isHost = false
                joinRoom(roomID: existingRoomID)
            } else {
                isHost = true
                createRoom()
            }
        } catch {
            setStatus(.error(message: String(describing: error)))
        }
    }

    public func stop() async {
        try? await deviceManager.removeRemoteDevice(address: portalAddress)

        portalBusTask?.cancel()
        portalBusTask = nil
        portalDevice = nil

        setStatus(.disconnected)
        roomID = nil
        localUser = nil
        participants = []
        chatMessages = []
    }

    public func sendChat(_ text: String) {
        guard case .joined = status, let device = portalDevice else { return }
        device.bus.post(["type": "chat-message", "payload": ["text": text]])
    }

    public func notifyEntryAdded(_ entry: NotebookEntry) {
        guard case .joined = status, let device = portalDevice else { return }
        device.bus.post(
            ["type": "add-entry", "payload": ["entry": entry.toJSON()]],
            data: entry.binaryData.map { [UInt8]($0) }
        )
    }

    public func notifyEntryUpdated(_ entry: NotebookEntry) {
        guard case .joined = status, let device = portalDevice else { return }
        let full = entry.toJSON()
        var payload: JSONObject = ["entry-id": full["id"] ?? entry.id.uuidString]
        for (k, v) in full where k != "id" { payload[k] = v }
        device.bus.post(["type": "update-entry", "payload": payload])
    }

    public func notifyEntryDeleted(id: UUID) {
        guard case .joined = status, let device = portalDevice else { return }
        device.bus.post(["type": "delete-entry", "payload": ["entry-id": id.uuidString]])
    }

    // MARK: - Room Operations

    private func createRoom() {
        guard let device = portalDevice else { return }
        device.bus.post(["type": "create-room", "payload": [:] as JSONObject])
        setStatus(.connecting)
    }

    private func joinRoom(roomID: String) {
        guard let device = portalDevice else { return }
        device.bus.post(["type": "join-room", "payload": ["id": roomID]])
        setStatus(.connecting)
    }

    // MARK: - Bus Event Handling

    private func handleBusEvent(_ event: Bus.Event) async {
        switch event {
        case .detached:
            await stop()

        case .message(message: let anyValue, let data):
            guard let dict = anyValue as? JSONObject,
                let type = dict["type"] as? String,
                let payload = dict["payload"] as? JSONObject
            else {
                await stop()
                return
            }

            await handleMessage(type: type, payload: payload, data: data)
        }
    }

    private func handleMessage(type: String, payload: JSONObject, data: [UInt8]?) async {
        switch type {
        case "welcome":
            if let userObj = payload["user"] as? JSONObject, let user = UserInfo.fromJSON(userObj) {
                localUser = user
            }

        case "room-created":
            guard let roomObj = payload["room"] as? JSONObject,
                let roomID = roomObj["id"] as? String,
                let localUser
            else {
                await stop()
                return
            }

            self.roomID = roomID
            setStatus(.joined(roomID: roomID))
            participants = [localUser]

            var collabState = try! store.fetchCollaborationState()
            collabState.roomID = roomID
            try! store.save(collabState)

            let entries = try! store.fetchNotebookEntries()
            for entry in entries {
                notifyEntryAdded(entry)
            }

        case "room-joined":
            guard
                let roomObj = payload["room"] as? JSONObject,
                let roomID = roomObj["id"] as? String,
                let participantDicts = payload["participants"] as? [JSONObject],
                let chatObj = payload["chat"] as? JSONObject,
                let chatMsgs = chatObj["messages"] as? [JSONObject],
                let notebookObj = payload["notebook"] as? JSONObject,
                let notebookEntries = notebookObj["entries"] as? [JSONObject],
                let binaryObj = payload["binary"] as? JSONObject,
                let binaryIndices = binaryObj["indices"] as? [Any],
                binaryIndices.count == notebookEntries.count,
                let localUser
            else {
                await stop()
                return
            }

            var snapshot: [NotebookEntry] = []
            for (i, obj) in notebookEntries.enumerated() {
                let indexInfo = binaryIndices[i]
                let binaryData: [UInt8]?
                if let idx = indexInfo as? JSONObject,
                    let start = idx["start"] as? Int,
                    let length = idx["length"] as? Int
                {
                    guard let slice = data?[start..<start + length] else {
                        await stop()
                        return
                    }
                    binaryData = Array(slice)
                } else {
                    binaryData = nil
                }

                guard let entry = NotebookEntry.fromJSON(obj, binaryData: binaryData) else {
                    await stop()
                    return
                }
                snapshot.append(entry)
            }

            self.roomID = roomID
            setStatus(.joined(roomID: roomID))
            participants = participantDicts.compactMap { UserInfo.fromJSON($0) }
            chatMessages = chatMsgs.compactMap { ChatMessage.fromJSON($0, localUser: localUser) }

            var collabState = try! store.fetchCollaborationState()
            collabState.roomID = roomID
            try! store.save(collabState)

            onNotebookEntriesReceived?(snapshot)

        case "entry-added":
            guard let entryObj = payload["entry"] as? JSONObject,
                let entry = NotebookEntry.fromJSON(entryObj, binaryData: data)
            else {
                await stop()
                return
            }
            onNotebookEntryAdded?(entry)

        case "entry-updated":
            guard let updatedObj = payload["entry"] as? JSONObject,
                let updated = NotebookEntry.fromJSON(updatedObj, binaryData: data)
            else {
                await stop()
                return
            }
            onNotebookEntryUpdated?(updated)

        case "entry-deleted":
            guard let entryObj = payload["entry"] as? JSONObject,
                let rawId = entryObj["id"] as? String,
                let id = UUID(uuidString: rawId)
            else {
                await stop()
                return
            }
            onNotebookEntryDeleted?(id)

        case "entries-reordered":
            guard let rawOrder = payload["order"] as? [String] else {
                await stop()
                return
            }
            let order = rawOrder.compactMap(UUID.init(uuidString:))
            if order.count != rawOrder.count {
                await stop()
                return
            }
            onEntriesReordered?(order)

        case "participant-joined":
            if let userObj = payload["user"] as? JSONObject, let user = UserInfo.fromJSON(userObj) {
                participants.append(user)
                onParticipantJoined?(user)
            }

        case "participant-left":
            if let userObj = payload["user"] as? JSONObject, let userID = userObj["id"] as? String {
                participants.removeAll { $0.id == userID }
                onParticipantLeft?(userID)
            }

        case "chat-message":
            if let localUser,
                let messageObj = payload["message"] as? JSONObject,
                let message = ChatMessage.fromJSON(messageObj, localUser: localUser)
            {
                chatMessages.append(message)
                onChatMessageReceived?(message)
            }

        case "error":
            let msg = String(describing: payload["code"] ?? "protocol error")
            setStatus(.error(message: msg))

        default:
            await stop()
        }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        _statusChanges.yield(newStatus)
    }
}
