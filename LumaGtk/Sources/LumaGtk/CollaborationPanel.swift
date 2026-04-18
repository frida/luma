import CPango
import Foundation
import Gdk
import Gtk
import LumaCore
import Observation

@MainActor
final class CollaborationPanel {
    let widget: Box

    private weak var engine: Engine?
    private let onClose: () -> Void

    private let identitySection: Box
    private let labSection: Box
    private let participantsSection: Box
    private let participantsList: ListBox
    private let chatSection: Box
    private let chatListBox: ListBox
    private let chatScroll: ScrolledWindow
    private let chatEntry: Entry
    private let chatSendButton: Button

    private let timeFormatter: DateFormatter
    private let chatTimeFormatter: DateFormatter

    private var copiedToastLabel: Label?
    private var copiedToastResetTask: Task<Void, Never>?
    private var isPinnedToBottom = true
    private var lastChatCount = 0
    private var suppressScrollPinUpdate = false
    private var signInWindow: Window?

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
        chatTimeFormatter = DateFormatter()
        chatTimeFormatter.dateFormat = "HH:mm"

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

        labSection = Box(orientation: .vertical, spacing: 6)
        widget.append(child: labSection)

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

        if let vadj = chatScroll.vadjustment {
            vadj.onValueChanged { [weak self] adj in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.suppressScrollPinUpdate { return }
                    let atBottom = (adj.upper - (adj.value + adj.pageSize)) < 20.0
                    self.isPinnedToBottom = atBottom
                }
            }
        }

        refreshIdentity()
        refreshLab()
        refreshParticipants()
        refreshChat()
        syncSignInSheet()
        observeIdentity()
        observeLab()
        observeParticipants()
        observeChat()
    }

    // MARK: - Observation

    private func observeIdentity() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.gitHubAuth.currentUser
            _ = engine.gitHubAuth.state
            _ = engine.gitHubAuth.isPresentingSignIn
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshIdentity()
                self.syncSignInSheet()
                self.observeIdentity()
            }
        }
    }

    private func syncSignInSheet() {
        guard let engine else { return }
        let wants = engine.gitHubAuth.isPresentingSignIn
        if wants && signInWindow == nil {
            let window = GitHubSignInSheet.present(
                from: widget,
                gitHubAuth: engine.gitHubAuth,
                onClosed: { [weak self] in
                    self?.signInWindow = nil
                }
            )
            signInWindow = window
        } else if !wants, let window = signInWindow {
            signInWindow = nil
            window.destroy()
        }
    }

    private func observeLab() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.collaboration.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshLab()
                self.refreshChatInputState()
                self.observeLab()
            }
        }
    }

    private func observeParticipants() {
        guard let engine else { return }
        engine.collaboration.onParticipantJoined = { [weak self] user in
            self?.appendParticipant(user)
        }
        engine.collaboration.onParticipantLeft = { [weak self] userID in
            self?.removeParticipant(userID)
        }
    }

    private func observeChat() {
        guard let engine else { return }
        engine.collaboration.onChatMessageReceived = { [weak self] message in
            self?.appendChatMessage(message)
        }
    }

    // MARK: - Refreshers

    private func refreshIdentity() {
        clearChildren(of: identitySection)
        guard let engine else { return }
        guard let user = engine.gitHubAuth.currentUser else {
            identitySection.visible = false
            return
        }

        identitySection.visible = true
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
    }

    private func refreshLab() {
        clearChildren(of: labSection)
        copiedToastLabel = nil
        copiedToastResetTask?.cancel()
        copiedToastResetTask = nil
        guard let engine else { return }

        switch engine.collaboration.status {
        case .disconnected:
            let storedLabID = (try? engine.store.fetchCollaborationState())?.labID
            if let stored = storedLabID {
                let hint = Box(orientation: .vertical, spacing: 4)
                hint.add(cssClass: "luma-linked-lab-hint")
                let hintLabel = Label(str: "This project is already linked to lab \(truncatedLabID(stored)).")
                hintLabel.halign = .start
                hintLabel.wrap = true
                hintLabel.add(cssClass: "caption")
                hintLabel.add(cssClass: "dim-label")
                hint.append(child: hintLabel)
                let reconnect = Button(label: "Reconnect")
                reconnect.halign = .start
                reconnect.onClicked { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.engine?.startCollaboration(joiningLab: stored)
                    }
                }
                hint.append(child: reconnect)
                labSection.append(child: hint)
            }

            let info = Label(str: "Not connected")
            info.halign = .start
            info.add(cssClass: "dim-label")
            labSection.append(child: info)

            let enable = Button(label: "Enable Collaboration")
            enable.add(cssClass: "suggested-action")
            enable.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine?.startCollaboration(joiningLab: nil)
                }
            }
            labSection.append(child: enable)

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
            labSection.append(child: row)

        case .joined(let labID):
            let roleLabel = Label(str: engine.collaboration.isHost ? "You are hosting this lab" : "You joined this lab")
            roleLabel.halign = .start
            roleLabel.add(cssClass: "caption")
            roleLabel.add(cssClass: "dim-label")
            labSection.append(child: roleLabel)

            let label = Label(str: "Lab: \(truncatedLabID(labID))")
            label.halign = .start
            label.selectable = true
            label.add(cssClass: "monospace")
            labSection.append(child: label)

            let inviteURL = "\(BackendConfig.inviteLinkBase)\(labID)"
            let inviteFrame = Box(orientation: .vertical, spacing: 4)
            inviteFrame.add(cssClass: "luma-invite-frame")

            let inviteHeader = Label(str: "Invite link")
            inviteHeader.halign = .start
            inviteHeader.add(cssClass: "caption-heading")
            inviteFrame.append(child: inviteHeader)

            let inviteRow = Box(orientation: .horizontal, spacing: 6)
            let urlLabel = Label(str: inviteURL)
            urlLabel.halign = .start
            urlLabel.hexpand = true
            urlLabel.selectable = true
            urlLabel.ellipsize = PangoEllipsizeMode(rawValue: 2)
            urlLabel.add(cssClass: "monospace")
            urlLabel.add(cssClass: "caption")
            inviteRow.append(child: urlLabel)

            let copyButton = Button(label: "Copy")
            copyButton.hasFrame = false
            copyButton.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    if let display = Display.getDefault() {
                        display.clipboard.set(text: inviteURL)
                    }
                    self?.showInviteCopiedToast()
                }
            }
            inviteRow.append(child: copyButton)
            inviteFrame.append(child: inviteRow)

            let toast = Label(str: "Copied!")
            toast.halign = .start
            toast.add(cssClass: "caption")
            toast.add(cssClass: "accent")
            toast.visible = false
            inviteFrame.append(child: toast)
            copiedToastLabel = toast

            labSection.append(child: inviteFrame)

            let leave = Button(label: "Leave")
            leave.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let engine = self?.engine else { return }
                    Task { @MainActor in
                        await engine.collaboration.stop()
                    }
                }
            }
            labSection.append(child: leave)

        case .error(let msg):
            let label = Label(str: msg)
            label.halign = .start
            label.wrap = true
            label.add(cssClass: "error")
            labSection.append(child: label)

            let retry = Button(label: "Retry")
            retry.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine?.startCollaboration(joiningLab: nil)
                }
            }
            labSection.append(child: retry)
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
        let messages = engine.collaboration.chatMessages
        for message in messages {
            let row = ListBoxRow()
            row.selectable = false
            row.activatable = false

            let outer = Box(orientation: .horizontal, spacing: 0)
            outer.marginStart = 4
            outer.marginEnd = 4
            outer.marginTop = 2
            outer.marginBottom = 2

            let bubble = Box(orientation: .vertical, spacing: 2)
            bubble.add(cssClass: message.isLocal ? "luma-chat-bubble-local" : "luma-chat-bubble-remote")
            bubble.hexpand = false
            bubble.halign = message.isLocal ? .end : .start

            let header = Box(orientation: .horizontal, spacing: 6)
            let senderName = message.isLocal
                ? "You"
                : (message.sender.name.isEmpty ? "@\(message.sender.id)" : message.sender.name)
            let senderLabel = Label(str: senderName)
            senderLabel.halign = .start
            senderLabel.hexpand = true
            senderLabel.add(cssClass: "caption-heading")
            header.append(child: senderLabel)

            let timeLabel = Label(str: chatTimeFormatter.string(from: message.timestamp))
            timeLabel.halign = .end
            timeLabel.add(cssClass: "caption")
            timeLabel.add(cssClass: "dim-label")
            header.append(child: timeLabel)
            bubble.append(child: header)

            let body = Label(str: message.text)
            body.halign = .start
            body.wrap = true
            body.xalign = 0
            body.add(cssClass: "caption")
            bubble.append(child: body)

            if message.isLocal {
                let spacer = Box(orientation: .horizontal, spacing: 0)
                spacer.hexpand = true
                outer.append(child: spacer)
                outer.append(child: bubble)
            } else {
                outer.append(child: bubble)
                let spacer = Box(orientation: .horizontal, spacing: 0)
                spacer.hexpand = true
                outer.append(child: spacer)
            }

            row.set(child: outer)
            chatListBox.append(child: row)
        }

        if messages.count != lastChatCount {
            lastChatCount = messages.count
            if isPinnedToBottom {
                scrollChatToBottomSoon()
            }
        }

        refreshChatInputState()
    }

    private func appendParticipant(_ user: LumaCore.CollaborationSession.UserInfo) {
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

    private func removeParticipant(_ userID: String) {
        guard let engine else { return }
        let participants = engine.collaboration.participants
        // Find by absence — the participant was already removed from the model
        participantsList.removeAll()
        for user in participants {
            appendParticipant(user)
        }
    }

    private func appendChatMessage(_ message: LumaCore.CollaborationSession.ChatMessage) {
        let row = ListBoxRow()
        row.selectable = false
        row.activatable = false

        let outer = Box(orientation: .horizontal, spacing: 0)
        outer.marginStart = 4
        outer.marginEnd = 4
        outer.marginTop = 2
        outer.marginBottom = 2

        let bubble = Box(orientation: .vertical, spacing: 2)
        bubble.add(cssClass: message.isLocal ? "luma-chat-bubble-local" : "luma-chat-bubble-remote")
        bubble.hexpand = false
        bubble.halign = message.isLocal ? .end : .start

        let header = Box(orientation: .horizontal, spacing: 6)
        let senderName = message.isLocal
            ? "You"
            : (message.sender.name.isEmpty ? "@\(message.sender.id)" : message.sender.name)
        let senderLabel = Label(str: senderName)
        senderLabel.halign = .start
        senderLabel.hexpand = true
        senderLabel.add(cssClass: "caption-heading")
        header.append(child: senderLabel)

        let timeLabel = Label(str: chatTimeFormatter.string(from: message.timestamp))
        timeLabel.halign = .end
        timeLabel.add(cssClass: "caption")
        timeLabel.add(cssClass: "dim-label")
        header.append(child: timeLabel)
        bubble.append(child: header)

        let body = Label(str: message.text)
        body.halign = .start
        body.wrap = true
        body.xalign = 0
        body.add(cssClass: "caption")
        bubble.append(child: body)

        if message.isLocal {
            let spacer = Box(orientation: .horizontal, spacing: 0)
            spacer.hexpand = true
            outer.append(child: spacer)
            outer.append(child: bubble)
        } else {
            outer.append(child: bubble)
            let spacer = Box(orientation: .horizontal, spacing: 0)
            spacer.hexpand = true
            outer.append(child: spacer)
        }

        row.set(child: outer)
        chatListBox.append(child: row)

        lastChatCount += 1
        if isPinnedToBottom {
            scrollChatToBottomSoon()
        }
        refreshChatInputState()
    }

    private func scrollChatToBottomSoon() {
        Task { @MainActor in
            guard let adj = chatScroll.vadjustment else { return }
            let target = adj.upper - adj.pageSize
            if target > adj.value {
                self.suppressScrollPinUpdate = true
                adj.value = target
                self.suppressScrollPinUpdate = false
                self.isPinnedToBottom = true
            }
        }
    }

    private func showInviteCopiedToast() {
        guard let toast = copiedToastLabel else { return }
        toast.visible = true
        copiedToastResetTask?.cancel()
        copiedToastResetTask = Task { @MainActor [weak self, weak toast] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self else { return }
            if self.copiedToastLabel === toast {
                toast?.visible = false
            }
        }
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

    private func truncatedLabID(_ id: String) -> String {
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
