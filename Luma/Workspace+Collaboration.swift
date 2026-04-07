import Foundation
import Frida
import LumaCore

extension Workspace {
    func bindProjectCollaboration() {
        let collabState = (try? store.fetchCollaborationState()) ?? LumaCore.ProjectCollaborationState()

        let roomFromLink = CollaborationJoinCoordinator.shared.consumeNextRoomID()
        storedProjectRoomID = roomFromLink ?? collabState.roomID

        wireCollaborationCallbacks()
        subscribeToCollaborationStatus()

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
        if let token = githubToken {
            Task { @MainActor in
                await engine.collaboration.start(token: token, existingRoomID: storedProjectRoomID)
                isCollaborationHost = engine.collaboration.isHost
            }
        } else {
            authState = .signedOut
            isAuthSheetPresented = true
        }
    }

    func stopCollaboration() {
        Task { @MainActor in
            await engine.collaboration.stop()
        }
    }

    func sendChatMessage(_ text: String) {
        engine.collaboration.sendChat(text)
    }

    func addNotebookEntry(_ entry: LumaCore.NotebookEntry, after otherEntry: LumaCore.NotebookEntry? = nil) {
        var e = entry
        if let otherEntry {
            e.timestamp = otherEntry.timestamp.addingTimeInterval(0.001)
        }
        try? store.save(e)
        engine.collaboration.notifyEntryAdded(e)
    }

    func notifyLocalNotebookEntryUpdated(_ entry: LumaCore.NotebookEntry) {
        try? store.save(entry)
        engine.collaboration.notifyEntryUpdated(entry)
    }

    func notifyLocalNotebookEntryDeleted(_ entry: LumaCore.NotebookEntry) {
        try? store.deleteNotebookEntry(id: entry.id)
        engine.collaboration.notifyEntryDeleted(id: entry.id)
    }

    private func wireCollaborationCallbacks() {
        let collab = engine.collaboration

        collab.onNotebookEntriesReceived = { [weak self] entries in
            guard let self else { return }
            for entry in entries {
                try? self.store.save(entry)
            }
        }

        collab.onNotebookEntryAdded = { [weak self] entry in
            guard let self else { return }
            if (try? self.store.fetchNotebookEntry(id: entry.id)) == nil {
                try? self.store.save(entry)
            }
        }

        collab.onNotebookEntryUpdated = { [weak self] updated in
            guard let self else { return }
            if var existing = try? self.store.fetchNotebookEntry(id: updated.id) {
                existing.title = updated.title
                existing.details = updated.details
                existing.timestamp = updated.timestamp
                existing.processName = updated.processName
                existing.isUserNote = updated.isUserNote
                try? self.store.save(existing)
            }
        }

        collab.onNotebookEntryDeleted = { [weak self] id in
            try? self?.store.deleteNotebookEntry(id: id)
        }

        collab.onEntriesReordered = { [weak self] order in
            guard let self else { return }
            var t = Date()
            for id in order {
                if var entry = try? self.store.fetchNotebookEntry(id: id) {
                    entry.timestamp = t
                    try? self.store.save(entry)
                    t = t.addingTimeInterval(0.001)
                }
            }
        }
    }

    private func subscribeToCollaborationStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await status in self.engine.collaboration.statusChanges {
                self.collaborationStatus = Self.mapCollaborationStatus(status)
                self.collaborationRoomID = self.engine.collaboration.roomID
                self.collaborationParticipants = self.engine.collaboration.participants.map { Workspace.UserInfo(from: $0) }
                self.collaborationChatMessages = self.engine.collaboration.chatMessages.map { Workspace.ChatMessage(from: $0) }
                if let user = self.engine.collaboration.localUser {
                    self.collaborationUser = Workspace.UserInfo(from: user)
                }
                if case .joined(let roomID) = status {
                    self.storedProjectRoomID = roomID
                }
            }
        }
    }

    private static func mapCollaborationStatus(_ status: CollaborationSession.Status) -> CollaborationStatus {
        switch status {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .joined(let id): return .joined(roomID: id)
        case .error(let msg): return .error(message: msg)
        }
    }
}

extension Workspace.UserInfo {
    init(from user: CollaborationSession.UserInfo) {
        self.init(id: user.id, displayName: user.name, avatarURL: user.avatarURL?.absoluteString ?? "")
    }
}

extension Workspace.ChatMessage {
    init(from message: CollaborationSession.ChatMessage) {
        self.init(
            user: Workspace.UserInfo(from: message.sender),
            text: message.text,
            timestamp: message.timestamp,
            isLocalUser: message.isLocal
        )
    }
}
