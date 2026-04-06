import Foundation
import Frida
import LumaCore

extension Workspace {
    func bindProjectCollaboration() {
        let collabState = (try? store.fetchCollaborationState()) ?? LumaCore.ProjectCollaborationState()

        let roomFromLink = CollaborationJoinCoordinator.shared.consumeNextRoomID()
        storedProjectRoomID = roomFromLink ?? collabState.roomID

        if roomFromLink != nil {
            isCollaborationPanelVisible = true
            startCollaboration()
        }
    }

    func signOut() {
        Task {
            TokenStore.delete(kind: .github)
            githubToken = nil
            currentGitHubUser = nil
            authState = .signedOut
            stopCollaboration()
        }
    }

    var isCollaborationActive: Bool {
        if case .joined = collaborationStatus { return true }
        return false
    }

    func startCollaboration() {
        if githubToken != nil {
            performStartCollaboration()
        } else {
            authState = .signedOut
            isAuthSheetPresented = true
        }
    }

    func performStartCollaboration() {
        guard let token = githubToken else { fatalError("Missing GitHub token") }

        precondition(
            {
                switch collaborationStatus {
                case .disconnected, .error:
                    return true
                default:
                    return false
                }
            }(), "startCollaboration() while not disconnected or error")
        collaborationStatus = .connecting

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let device = try await deviceManager.addRemoteDevice(
                    address: BackendConfig.portalAddress,
                    certificate: BackendConfig.certificate,
                    origin: nil,
                    token: token,
                    keepaliveInterval: nil
                )
                self.portalDevice = device

                let busEvents = device.bus.events
                self.portalBusTask?.cancel()
                self.portalBusTask = Task { @MainActor [weak self] in
                    guard let self else { return }

                    for await event in busEvents {
                        await self.handlePortalBusEvent(event)
                    }
                }

                try await device.bus.attach()

                if let existingRoomID = self.storedProjectRoomID {
                    self.isCollaborationHost = false
                    self.joinCollaborationRoom(roomID: existingRoomID)
                } else {
                    self.isCollaborationHost = true
                    self.createCollaborationRoom()
                }
            } catch {
                self.collaborationStatus = .error(message: String(describing: error))
            }
        }
    }

    func stopCollaboration() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            try? await self.deviceManager.removeRemoteDevice(address: BackendConfig.portalAddress)

            self.portalBusTask?.cancel()
            self.portalBusTask = nil
            self.portalDevice = nil

            self.collaborationStatus = .disconnected
            self.collaborationRoomID = nil
            self.collaborationUser = nil
            self.collaborationParticipants = []
            self.collaborationChatMessages = []
        }
    }

    func createCollaborationRoom() {
        guard let device = portalDevice else { return }

        device.bus.post([
            "type": "create-room",
            "payload": [:],
        ])
        collaborationStatus = .connecting
    }

    func joinCollaborationRoom(roomID: String) {
        guard let device = portalDevice else { return }

        device.bus.post([
            "type": "join-room",
            "payload": [
                "id": roomID
            ],
        ])
        collaborationStatus = .connecting
    }

    func sendChatMessage(_ text: String) {
        guard case .joined = collaborationStatus,
            let device = portalDevice
        else {
            return
        }

        device.bus.post([
            "type": "chat-message",
            "payload": [
                "text": text
            ],
        ])
    }

    private func handlePortalBusEvent(_ event: Bus.Event) async {
        switch event {
        case .detached:
            stopCollaboration()

        case .message(message: let anyValue, let data):
            guard let dict = anyValue as? JSONObject,
                let type = dict["type"] as? String,
                let payload = dict["payload"] as? JSONObject
            else {
                stopCollaboration()
                return
            }

            await handlePortalMessage(type: type, payload: payload, data: data)
        }
    }

    private func handlePortalMessage(type: String, payload: JSONObject, data: [UInt8]?) async {
        switch type {
        case "welcome":
            await handleWelcome(payload: payload)

        case "room-created":
            await handleRoomCreated(payload: payload)

        case "room-joined":
            await handleRoomJoined(payload: payload, combinedData: data)

        case "entry-added":
            await handleEntryAdded(payload: payload, binaryData: data)

        case "entry-updated":
            await handleEntryUpdated(payload: payload, binaryData: data)

        case "entries-reordered":
            await handleEntriesReordered(payload: payload)

        case "entry-deleted":
            await handleEntryDeleted(payload: payload)

        case "participant-joined":
            await handleParticipantJoined(payload: payload)

        case "participant-left":
            await handleParticipantLeft(payload: payload)

        case "chat-message":
            await handleChatMessageReceived(payload: payload)

        case "error":
            let msg = String(describing: payload["code"] ?? "protocol error")
            collaborationStatus = .error(message: msg)

        default:
            stopCollaboration()
        }
    }

    private func handleWelcome(payload: JSONObject) async {
        guard
            let user = payload["user"] as? JSONObject,
            let user = UserInfo.fromJSON(user)
        else {
            return
        }

        collaborationUser = user
    }

    private func handleRoomCreated(payload: JSONObject) async {
        guard let roomObj = payload["room"] as? JSONObject,
            let roomID = roomObj["id"] as? String,
            let localUser = collaborationUser
        else {
            stopCollaboration()
            return
        }

        var collabState = (try? store.fetchCollaborationState()) ?? LumaCore.ProjectCollaborationState()
        collabState.roomID = roomID
        try? store.save(collabState)

        collaborationRoomID = roomID
        collaborationStatus = .joined(roomID: roomID)
        collaborationParticipants = [localUser]
        storedProjectRoomID = roomID

        for entry in notebookEntries {
            portalDevice!.bus.post(
                [
                    "type": "add-entry",
                    "payload": [
                        "entry": entry.toJSON()
                    ],
                ], data: entry.binaryData.map { [UInt8]($0) })
        }
    }

    private func handleRoomJoined(payload: JSONObject, combinedData: [UInt8]?) async {
        guard
            let roomObj = payload["room"] as? JSONObject,
            let roomID = roomObj["id"] as? String,
            let participants = payload["participants"] as? [JSONObject],
            let chatObj = payload["chat"] as? JSONObject,
            let chatMessages = chatObj["messages"] as? [JSONObject],
            let notebookObj = payload["notebook"] as? JSONObject,
            let notebookEntries = notebookObj["entries"] as? [JSONObject],
            let binaryObj = payload["binary"] as? JSONObject,
            let binaryIndices = binaryObj["indices"] as? [Any],
            binaryIndices.count == notebookEntries.count
        else {
            stopCollaboration()
            return
        }

        var snapshot: [LumaCore.NotebookEntry] = []
        for (i, obj) in notebookEntries.enumerated() {
            let indexInfo = binaryIndices[i]

            let binaryData: [UInt8]?
            if let idx = indexInfo as? JSONObject,
                let start = idx["start"] as? Int,
                let length = idx["length"] as? Int
            {
                guard let slice = combinedData?[start..<start + length] else {
                    stopCollaboration()
                    return
                }
                binaryData = Array(slice)
            } else {
                binaryData = nil
            }

            guard let entry = LumaCore.NotebookEntry.fromJSON(obj, binaryData: binaryData) else {
                stopCollaboration()
                return
            }

            snapshot.append(entry)
        }

        var collabState = (try? store.fetchCollaborationState()) ?? LumaCore.ProjectCollaborationState()
        collabState.roomID = roomID
        try? store.save(collabState)

        collaborationRoomID = roomID
        collaborationStatus = .joined(roomID: roomID)
        collaborationParticipants = participants.compactMap { UserInfo.fromJSON($0) }
        collaborationChatMessages = chatMessages.compactMap { ChatMessage.fromJSON($0, localUser: collaborationUser!) }

        for entry in snapshot {
            self.notebookEntries.append(entry)
            try? store.save(entry)
        }
    }

    func addNotebookEntry(_ entry: LumaCore.NotebookEntry, after otherEntry: LumaCore.NotebookEntry? = nil) {
        var e = entry
        if let otherEntry {
            e.timestamp = otherEntry.timestamp.addingTimeInterval(0.001)
        }

        notebookEntries.append(e)
        try? store.save(e)
        notifyLocalNotebookEntryAdded(e)
    }

    private func notifyLocalNotebookEntryAdded(_ entry: LumaCore.NotebookEntry) {
        guard case .joined = collaborationStatus, let device = portalDevice else { return }
        device.bus.post(
            [
                "type": "add-entry",
                "payload": [
                    "entry": entry.toJSON()
                ],
            ], data: entry.binaryData.map { [UInt8]($0) })
    }

    func notifyLocalNotebookEntryUpdated(_ entry: LumaCore.NotebookEntry) {
        try? store.save(entry)
        guard case .joined = collaborationStatus, let device = portalDevice else { return }
        let full = entry.toJSON()
        var payload: JSONObject = ["entry-id": full["id"] ?? entry.id.uuidString]
        for (k, v) in full where k != "id" { payload[k] = v }
        device.bus.post([
            "type": "update-entry",
            "payload": payload,
        ])
    }

    func notifyLocalNotebookEntryDeleted(_ entry: LumaCore.NotebookEntry) {
        try? store.deleteNotebookEntry(id: entry.id)
        guard case .joined = collaborationStatus, let device = portalDevice else { return }
        device.bus.post([
            "type": "delete-entry",
            "payload": ["entry-id": entry.id.uuidString],
        ])
    }

    private func handleEntryAdded(payload: JSONObject, binaryData: [UInt8]?) async {
        guard
            let entryObj = payload["entry"] as? JSONObject,
            let entry = LumaCore.NotebookEntry.fromJSON(entryObj, binaryData: binaryData)
        else {
            stopCollaboration()
            return
        }

        guard !notebookEntries.contains(where: { $0.id == entry.id }) else {
            return
        }

        notebookEntries.append(entry)
        try? store.save(entry)
    }

    private func handleEntryUpdated(payload: JSONObject, binaryData: [UInt8]?) async {
        guard
            let updatedObj = payload["entry"] as? JSONObject,
            let updated = LumaCore.NotebookEntry.fromJSON(updatedObj, binaryData: binaryData)
        else {
            stopCollaboration()
            return
        }

        guard let idx = notebookEntries.firstIndex(where: { $0.id == updated.id }) else {
            return
        }

        notebookEntries[idx].title = updated.title
        notebookEntries[idx].details = updated.details
        notebookEntries[idx].timestamp = updated.timestamp
        notebookEntries[idx].processName = updated.processName
        notebookEntries[idx].isUserNote = updated.isUserNote
        try? store.save(notebookEntries[idx])
    }

    private func handleEntryDeleted(payload: JSONObject) async {
        guard
            let entryObj = payload["entry"] as? JSONObject,
            let rawId = entryObj["id"] as? String,
            let id = UUID.init(uuidString: rawId)
        else {
            stopCollaboration()
            return
        }

        guard notebookEntries.contains(where: { $0.id == id }) else {
            return
        }

        notebookEntries.removeAll { $0.id == id }
        try? store.deleteNotebookEntry(id: id)
    }

    private func handleEntriesReordered(payload: JSONObject) async {
        guard let rawOrder = payload["order"] as? [String] else {
            stopCollaboration()
            return
        }

        let order = rawOrder.compactMap(UUID.init(uuidString:))
        if order.count != rawOrder.count {
            stopCollaboration()
            return
        }

        var t = Date()
        for id in order {
            if let idx = notebookEntries.firstIndex(where: { $0.id == id }) {
                notebookEntries[idx].timestamp = t
                try? store.save(notebookEntries[idx])
                t = t.addingTimeInterval(0.001)
            }
        }
    }

    private func handleParticipantJoined(payload: JSONObject) async {
        guard
            let userObj = payload["user"] as? JSONObject,
            let user = UserInfo.fromJSON(userObj)
        else {
            return
        }

        collaborationParticipants.append(user)
    }

    private func handleParticipantLeft(payload: JSONObject) async {
        guard
            let userObj = payload["user"] as? JSONObject,
            let userID = userObj["id"] as? String
        else {
            return
        }

        collaborationParticipants.removeAll { $0.id == userID }
    }

    private func handleChatMessageReceived(payload: JSONObject) async {
        guard
            let localUser = collaborationUser,
            let messageObj = payload["message"] as? JSONObject,
            let message = ChatMessage.fromJSON(messageObj, localUser: localUser)
        else {
            return
        }

        collaborationChatMessages.append(message)
    }
}
