import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class CollaborationPanel {
    let widget: Box

    private weak var engine: Engine?
    private let onClose: () -> Void

    private let identitySection: Box
    private let roomSection: Box
    private let participantsSection: Box
    private let participantsList: ListBox
    private let chatSection: Box
    private let chatListBox: ListBox
    private let chatScroll: ScrolledWindow
    private let chatEntry: Entry
    private let chatSendButton: Button

    private let timeFormatter: DateFormatter

    init(engine: Engine, onClose: @escaping () -> Void) {
        self.engine = engine
        self.onClose = onClose

        widget = Box(orientation: .vertical, spacing: 8)
        widget.add(cssClass: "collaboration-panel")
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12
        widget.hexpand = false
        widget.vexpand = true
        widget.setSizeRequest(width: 280, height: -1)

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        let header = Box(orientation: .horizontal, spacing: 8)
        let title = Label(str: "Collaboration")
        title.add(cssClass: "title-4")
        title.halign = .start
        title.hexpand = true
        header.append(child: title)
        let closeButton = Button(label: "✕")
        closeButton.hasFrame = false
        header.append(child: closeButton)
        widget.append(child: header)

        widget.append(child: Separator(orientation: .horizontal))

        identitySection = Box(orientation: .vertical, spacing: 6)
        widget.append(child: identitySection)

        widget.append(child: Separator(orientation: .horizontal))

        roomSection = Box(orientation: .vertical, spacing: 6)
        widget.append(child: roomSection)

        widget.append(child: Separator(orientation: .horizontal))

        participantsSection = Box(orientation: .vertical, spacing: 4)
        let participantsHeader = Label(str: "PARTICIPANTS")
        participantsHeader.halign = .start
        participantsHeader.add(cssClass: "heading")
        participantsSection.append(child: participantsHeader)
        participantsList = ListBox()
        participantsList.add(cssClass: "navigation-sidebar")
        participantsList.selectionMode = .none
        participantsSection.append(child: participantsList)
        widget.append(child: participantsSection)

        widget.append(child: Separator(orientation: .horizontal))

        chatSection = Box(orientation: .vertical, spacing: 6)
        chatSection.vexpand = true
        let chatHeader = Label(str: "CHAT")
        chatHeader.halign = .start
        chatHeader.add(cssClass: "heading")
        chatSection.append(child: chatHeader)

        chatListBox = ListBox()
        chatListBox.selectionMode = .none
        chatScroll = ScrolledWindow()
        chatScroll.hexpand = true
        chatScroll.vexpand = true
        chatScroll.setSizeRequest(width: -1, height: 160)
        chatScroll.set(child: chatListBox)
        chatSection.append(child: chatScroll)

        let inputRow = Box(orientation: .horizontal, spacing: 6)
        chatEntry = Entry()
        chatEntry.hexpand = true
        chatEntry.placeholderText = "Message\u{2026}"
        inputRow.append(child: chatEntry)
        chatSendButton = Button(label: "Send")
        inputRow.append(child: chatSendButton)
        chatSection.append(child: inputRow)

        widget.append(child: chatSection)

        closeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onClose()
            }
        }

        chatEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sendChat()
            }
        }
        chatSendButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sendChat()
            }
        }

        refreshIdentity()
        refreshRoom()
        refreshParticipants()
        refreshChat()
        observeIdentity()
        observeRoom()
        observeParticipants()
        observeChat()
    }

    // MARK: - Observation

    private func observeIdentity() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.gitHubAuth.currentUser
            _ = engine.gitHubAuth.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshIdentity()
                self.observeIdentity()
            }
        }
    }

    private func observeRoom() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.collaboration.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshRoom()
                self.refreshChatInputState()
                self.observeRoom()
            }
        }
    }

    private func observeParticipants() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.collaboration.participants
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshParticipants()
                self.observeParticipants()
            }
        }
    }

    private func observeChat() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.collaboration.chatMessages
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshChat()
                self.observeChat()
            }
        }
    }

    // MARK: - Refreshers

    private func refreshIdentity() {
        clearChildren(of: identitySection)
        guard let engine else { return }

        if let user = engine.gitHubAuth.currentUser {
            let row = Box(orientation: .horizontal, spacing: 8)
            let label = Label(str: "@\(user.id)")
            label.halign = .start
            label.hexpand = true
            row.append(child: label)
            let signOut = Button(label: "Sign out")
            signOut.hasFrame = false
            signOut.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let engine = self?.engine else { return }
                    Task { @MainActor in
                        await engine.gitHubAuth.signOut()
                        await engine.collaboration.stop()
                    }
                }
            }
            row.append(child: signOut)
            identitySection.append(child: row)
        } else {
            let signIn = Button(label: "Sign in to GitHub\u{2026}")
            signIn.add(cssClass: "suggested-action")
            signIn.onClicked { [weak self, weak signIn] _ in
                MainActor.assumeIsolated {
                    guard let engine = self?.engine, let anchor = signIn else { return }
                    GitHubSignInSheet.present(from: anchor, gitHubAuth: engine.gitHubAuth)
                    engine.gitHubAuth.beginSignIn()
                }
            }
            identitySection.append(child: signIn)
        }

        if case .failed(let reason) = engine.gitHubAuth.state {
            let err = Label(str: reason)
            err.halign = .start
            err.add(cssClass: "error")
            err.wrap = true
            identitySection.append(child: err)
        }
    }

    private func refreshRoom() {
        clearChildren(of: roomSection)
        guard let engine else { return }

        switch engine.collaboration.status {
        case .disconnected:
            let info = Label(str: "Not connected")
            info.halign = .start
            info.add(cssClass: "dim-label")
            roomSection.append(child: info)

            let enable = Button(label: "Enable Collaboration")
            enable.add(cssClass: "suggested-action")
            enable.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine?.startCollaboration(joiningRoom: nil)
                }
            }
            roomSection.append(child: enable)

        case .connecting:
            let row = Box(orientation: .horizontal, spacing: 6)
            let spinner = Spinner()
            spinner.spinning = true
            spinner.start()
            row.append(child: spinner)
            let label = Label(str: "Connecting\u{2026}")
            label.halign = .start
            label.hexpand = true
            row.append(child: label)
            roomSection.append(child: row)

        case .joined(let roomID):
            let label = Label(str: "Room: \(truncatedRoomID(roomID))")
            label.halign = .start
            label.selectable = true
            label.add(cssClass: "monospace")
            roomSection.append(child: label)

            let leave = Button(label: "Leave")
            leave.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let engine = self?.engine else { return }
                    Task { @MainActor in
                        await engine.collaboration.stop()
                    }
                }
            }
            roomSection.append(child: leave)

        case .error(let msg):
            let label = Label(str: msg)
            label.halign = .start
            label.wrap = true
            label.add(cssClass: "error")
            roomSection.append(child: label)

            let retry = Button(label: "Retry")
            retry.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine?.startCollaboration(joiningRoom: nil)
                }
            }
            roomSection.append(child: retry)
        }
    }

    private func refreshParticipants() {
        guard let engine else { return }
        participantsList.removeAll()
        for user in engine.collaboration.participants {
            let row = ListBoxRow()
            let label = Label(str: user.name.isEmpty ? "@\(user.id)" : user.name)
            label.halign = .start
            label.marginStart = 8
            label.marginEnd = 8
            label.marginTop = 2
            label.marginBottom = 2
            row.set(child: label)
            participantsList.append(child: row)
        }
    }

    private func refreshChat() {
        guard let engine else { return }
        chatListBox.removeAll()
        for message in engine.collaboration.chatMessages {
            let row = ListBoxRow()
            let line = Label(str: "\(message.sender.name.isEmpty ? "@\(message.sender.id)" : message.sender.name): \(message.text)")
            line.halign = .start
            line.wrap = true
            line.marginStart = 6
            line.marginEnd = 6
            line.marginTop = 2
            line.marginBottom = 2
            if message.isLocal {
                line.add(cssClass: "accent")
            }
            row.set(child: line)
            chatListBox.append(child: row)
        }
        refreshChatInputState()
    }

    private func refreshChatInputState() {
        guard let engine else { return }
        let isJoined: Bool
        if case .joined = engine.collaboration.status { isJoined = true } else { isJoined = false }
        chatEntry.sensitive = isJoined
        chatSendButton.sensitive = isJoined
    }

    private func sendChat() {
        guard let engine else { return }
        let text = (chatEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if case .joined = engine.collaboration.status {
            engine.collaboration.sendChat(text)
            chatEntry.text = ""
        }
    }

    private func truncatedRoomID(_ id: String) -> String {
        if id.count <= 12 { return id }
        return String(id.prefix(12)) + "\u{2026}"
    }

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}
