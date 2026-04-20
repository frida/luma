import Adw
import CLuma
import CPango
import Foundation
import Gdk
import GdkPixBuf
import Gtk
import LumaCore
import Observation

@MainActor
final class CollaborationPanel {
    let widget: Box

    private weak var engine: Engine?
    private weak var desktopNotifier: DesktopNotifier?
    private let onClose: () -> Void

    private let headerBox: Box
    private let headerAvatarHost: Box
    private let labSection: Box
    private let activeCollaboration: Box
    private let participantsStrip: Box
    private let participantsScroll: ScrolledWindow
    private let notificationsButton: Button
    private let chatListBox: ListBox
    private let chatScroll: ScrolledWindow
    private let chatEntry: Entry
    private let chatSendButton: Button

    private let chatTimeFormatter: DateFormatter

    private var participantWidgets: [String: Widget] = [:]
    private var copiedToastLabel: Label?
    private var copiedToastResetTask: Task<Void, Never>?
    private var isPinnedToBottom = true
    private var lastChatCount = 0
    private var suppressScrollPinUpdate = false
    private var signInWindow: Adw.Dialog?
    private var isEditingLabTitle: Bool = false
    private var chatTimestamps: [(label: Label, date: Date)] = []
    private var tickerTask: Task<Void, Never>?

    private static let headerAvatarSize: Int = 24
    private static let participantAvatarSize: Int = 28
    private static let chatAvatarSize: Int = 20

    init(engine: Engine, desktopNotifier: DesktopNotifier, onClose: @escaping () -> Void) {
        self.engine = engine
        self.desktopNotifier = desktopNotifier
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

        chatTimeFormatter = DateFormatter()
        chatTimeFormatter.dateFormat = "HH:mm"

        headerBox = Box(orientation: .horizontal, spacing: 8)
        let title = Label(str: "Collaboration")
        title.add(cssClass: "title-4")
        title.halign = .start
        title.hexpand = true
        headerBox.append(child: title)

        headerAvatarHost = Box(orientation: .horizontal, spacing: 0)
        headerBox.append(child: headerAvatarHost)

        let closeButton = Button(label: "✕")
        closeButton.hasFrame = false
        headerBox.append(child: closeButton)
        widget.append(child: headerBox)

        widget.append(child: Separator(orientation: .horizontal))

        labSection = Box(orientation: .vertical, spacing: 6)
        widget.append(child: labSection)

        activeCollaboration = Box(orientation: .vertical, spacing: 8)
        activeCollaboration.vexpand = true
        activeCollaboration.visible = false
        widget.append(child: activeCollaboration)

        activeCollaboration.append(child: Separator(orientation: .horizontal))

        let participantsSection = Box(orientation: .vertical, spacing: 4)
        let participantsHeader = Label(str: "PARTICIPANTS")
        participantsHeader.halign = .start
        participantsHeader.hexpand = true
        participantsHeader.add(cssClass: "heading")
        participantsSection.append(child: participantsHeader)

        // The notifications affordance is a lab-level control and lives
        // in labSection, rendered by refreshLab() when needed.
        let notificationsButton = Button(label: "Enable notifications")
        notificationsButton.add(cssClass: "suggested-action")
        notificationsButton.tooltipText = "Open your browser to allow Web Push notifications"

        participantsStrip = Box(orientation: .horizontal, spacing: 6)
        participantsStrip.marginTop = 2
        participantsStrip.marginBottom = 2
        participantsScroll = ScrolledWindow()
        participantsScroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
        participantsScroll.hexpand = true
        participantsScroll.setSizeRequest(width: -1, height: Self.participantAvatarSize + 8)
        participantsScroll.set(child: participantsStrip)
        participantsSection.append(child: participantsScroll)

        self.notificationsButton = notificationsButton

        activeCollaboration.append(child: participantsSection)

        activeCollaboration.append(child: Separator(orientation: .horizontal))

        let chatSection = Box(orientation: .vertical, spacing: 6)
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

        activeCollaboration.append(child: chatSection)

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

        notificationsButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.enableBrowserNotifications()
            }
        }

        refreshIdentity()
        refreshLab()
        refreshParticipants()
        refreshChat()
        refreshNotificationsButton()
        syncSignInSheet()
        observeIdentity()
        observeLab()
        observeParticipants()
        observeChat()
        startRelativeTimeTicker()
    }

    deinit {
        tickerTask?.cancel()
    }

    private func startRelativeTimeTicker() {
        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                for entry in self.chatTimestamps {
                    entry.label.label = RelativeTime.string(from: entry.date, now: now)
                }
            }
        }
    }

    private func refreshNotificationsButton() {
        guard let engine else {
            notificationsButton.visible = false
            return
        }
        let isJoined: Bool
        if case .joined = engine.collaboration.status { isJoined = true } else { isJoined = false }
        let needsEnrollment = !engine.collaboration.registeredPushPlatforms.contains("web")
        notificationsButton.visible = isJoined && needsEnrollment
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
                self.refreshLab()
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
            _ = window.close()
        }
    }

    private func observeLab() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.collaboration.status
            _ = engine.collaboration.labTitle
            _ = engine.collaboration.labPictureData
            _ = engine.collaboration.registeredPushPlatforms
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshLab()
                self.refreshParticipants()
                self.refreshChat()
                self.refreshChatInputState()
                self.refreshNotificationsButton()
                self.observeLab()
            }
        }
    }

    private func makeLabPictureButton() -> Widget {
        let imageWidget = makeLabPictureImage(size: 48)

        guard engine?.collaboration.isOwner == true else {
            return imageWidget
        }

        let menuButton = MenuButton()
        menuButton.hasFrame = false
        menuButton.add(cssClass: "flat")
        menuButton.tooltipText = "Change lab picture"
        menuButton.set(child: imageWidget)

        let menuBox = Box(orientation: .vertical, spacing: 2)
        menuBox.marginStart = 6
        menuBox.marginEnd = 6
        menuBox.marginTop = 6
        menuBox.marginBottom = 6

        let uploadButton = Button(label: "Upload image\u{2026}")
        uploadButton.add(cssClass: "flat")
        uploadButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openLabPicturePicker()
            }
        }
        menuBox.append(child: uploadButton)

        if engine?.collaboration.labPictureData != nil {
            let resetButton = Button(label: "Reset to default")
            resetButton.add(cssClass: "flat")
            resetButton.add(cssClass: "luma-menu-destructive")
            resetButton.onClicked { [weak engine] _ in
                MainActor.assumeIsolated {
                    guard let engine else { return }
                    Task { @MainActor in await engine.collaboration.removeLabPicture() }
                }
            }
            menuBox.append(child: resetButton)
        }

        let popover = Popover()
        popover.autohide = true
        popover.set(child: menuBox)
        menuButton.set(popover: popover)
        return menuButton
    }

    private func makeLabPictureImage(size: Int) -> Widget {
        if let data = engine?.collaboration.labPictureData,
           let texture = IconPixbuf.makeTexture(fromEncodedData: data) {
            let image = Gtk.Image(paintable: texture)
            image.pixelSize = size
            image.add(cssClass: "luma-lab-picture")
            return image
        }
        // Fall back to owner avatar.
        let owner = engine?.collaboration.members.first(where: { $0.role == .owner })
        let name = owner.map { $0.user.name.isEmpty ? "@\($0.user.id)" : $0.user.name } ?? "Lab"
        let avatar = Adw.Avatar(size: size, text: name, showInitials: true)
        if let url = owner?.user.avatarURL {
            let sized = URL(string: "\(url.absoluteString)&s=\(size * 2)") ?? url
            Task { @MainActor [avatar] in
                guard let texture = await AvatarCache.shared.texture(for: sized) else { return }
                avatar.set(customImage: texture)
            }
        }
        return avatar
    }

    private func openLabPicturePicker() {
        guard let engine else { return }
        guard let rootPtr = widget.root?.ptr else { return }
        let parentPtr = UnsafeMutableRawPointer(rootPtr)
        let context = Unmanaged.passRetained(LabPictureContext(engine: engine)).toOpaque()
        "Choose lab picture".withCString { title in
            luma_file_dialog_open(parentPtr, title, labPicturePathThunk, context)
        }
    }

    private func makeLabTitleRow() -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        row.hexpand = true

        if isEditingLabTitle, engine?.collaboration.isOwner == true {
            let entry = Entry()
            entry.text = engine?.collaboration.labTitle ?? ""
            entry.placeholderText = "Title"
            entry.hexpand = true
            row.append(child: entry)

            let commit: () -> Void = { [weak self] in
                guard let self, let engine = self.engine else { return }
                let trimmed = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.isEditingLabTitle = false
                if !trimmed.isEmpty, trimmed != engine.collaboration.labTitle {
                    Task { @MainActor in
                        await engine.collaboration.setLabTitle(trimmed)
                    }
                }
                self.refreshLab()
            }
            let cancel: () -> Void = { [weak self] in
                self?.isEditingLabTitle = false
                self?.refreshLab()
            }

            entry.onActivate { _ in MainActor.assumeIsolated { commit() } }

            let saveButton = Button(label: "Save")
            saveButton.add(cssClass: "suggested-action")
            saveButton.onClicked { _ in MainActor.assumeIsolated { commit() } }
            row.append(child: saveButton)

            let cancelButton = Button(label: "Cancel")
            cancelButton.hasFrame = false
            cancelButton.add(cssClass: "flat")
            cancelButton.onClicked { _ in MainActor.assumeIsolated { cancel() } }
            row.append(child: cancelButton)

            Task { @MainActor in _ = entry.grabFocus() }
        } else {
            let title = Label(str: engine?.collaboration.labTitle ?? "Untitled")
            title.halign = .start
            title.hexpand = true
            title.wrap = true
            title.xalign = 0
            title.add(cssClass: "title-4")
            title.selectable = true
            row.append(child: title)

            if engine?.collaboration.isOwner == true {
                let editButton = Button()
                editButton.hasFrame = false
                editButton.set(iconName: "document-edit-symbolic")
                editButton.tooltipText = "Rename lab"
                editButton.onClicked { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isEditingLabTitle = true
                        self?.refreshLab()
                    }
                }
                row.append(child: editButton)
            }
        }
        return row
    }

    private func observeParticipants() {
        guard let engine else { return }
        engine.collaboration.onMemberAdded = { [weak self] member in
            guard let self else { return }
            self.addParticipant(member.user)
            guard let engine = self.engine,
                  !engine.collaboration.isSelf(member.user.id)
            else { return }
            self.desktopNotifier?.notifyMemberAdded(member, labID: engine.collaboration.labID)
        }
        engine.collaboration.onMemberRemoved = { [weak self] userID in
            self?.removeParticipant(userID)
        }
        engine.collaboration.onMemberPresenceChanged = { [weak self] _, _ in
            self?.refreshParticipants()
        }
    }

    private func observeChat() {
        guard let engine else { return }
        engine.collaboration.onChatMessageReceived = { [weak self] message in
            guard let self else { return }
            self.appendChatMessage(message)
            guard !message.isLocal, let engine = self.engine else { return }
            self.desktopNotifier?.notifyChatMessage(message, labID: engine.collaboration.labID)
        }
    }

    // MARK: - Refreshers

    private func refreshIdentity() {
        clearChildren(of: headerAvatarHost)
        guard let engine, let user = engine.gitHubAuth.currentUser else { return }

        let menuButton = MenuButton()
        menuButton.hasFrame = false
        menuButton.tooltipText = user.name.isEmpty ? "@\(user.id)" : user.name
        menuButton.add(cssClass: "flat")
        menuButton.add(cssClass: "luma-avatar-button")

        let avatar = makeAvatar(for: user, size: Self.headerAvatarSize)
        avatar.tooltipText = nil
        menuButton.set(child: avatar)

        let popover = Popover()
        popover.autohide = true
        let menuBox = Box(orientation: .vertical, spacing: 2)
        menuBox.marginStart = 6
        menuBox.marginEnd = 6
        menuBox.marginTop = 6
        menuBox.marginBottom = 6

        let profileButton = Button(label: "View GitHub Profile")
        profileButton.add(cssClass: "flat")
        profileButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                self?.openGitHubProfile(for: user)
                popover?.popdown()
            }
        }
        menuBox.append(child: profileButton)

        let signOutButton = Button(label: "Sign out")
        signOutButton.add(cssClass: "flat")
        signOutButton.add(cssClass: "luma-menu-destructive")
        signOutButton.onClicked { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                guard let engine = self?.engine else { return }
                Task { @MainActor in
                    await engine.gitHubAuth.signOut()
                    await engine.collaboration.stop()
                }
                popover?.popdown()
            }
        }
        menuBox.append(child: signOutButton)

        popover.set(child: menuBox)
        menuButton.set(popover: popover)

        headerAvatarHost.append(child: menuButton)
    }

    private func refreshLab() {
        clearChildren(of: labSection)
        copiedToastLabel = nil
        copiedToastResetTask?.cancel()
        copiedToastResetTask = nil
        guard let engine else { return }

        let status = engine.collaboration.status
        if case .joined = status {
            activeCollaboration.visible = true
        } else {
            activeCollaboration.visible = false
        }

        switch status {
        case .disconnected:
            let storedLabID = (try? engine.store.fetchCollaborationState())?.labID
            if let stored = storedLabID {
                let hintLabel = Label(
                    str: "This project is already linked to a shared notebook (lab \(truncatedLabID(stored))).")
                hintLabel.halign = .start
                hintLabel.wrap = true
                hintLabel.xalign = 0
                hintLabel.add(cssClass: "caption")
                hintLabel.add(cssClass: "dim-label")
                labSection.append(child: hintLabel)

                let explanation = Label(
                    str:
                        "Enable collaboration to rejoin that shared lab. Any other copies of this project will connect to the same notebook."
                )
                explanation.halign = .start
                explanation.wrap = true
                explanation.xalign = 0
                explanation.add(cssClass: "caption")
                explanation.add(cssClass: "dim-label")
                labSection.append(child: explanation)
            } else {
                let info = Label(str: "Collaboration is currently off for this project.")
                info.halign = .start
                info.wrap = true
                info.xalign = 0
                info.add(cssClass: "caption")
                info.add(cssClass: "dim-label")
                labSection.append(child: info)

                let explanation = Label(str: "Enable collaboration to create a shared notebook and chat.")
                explanation.halign = .start
                explanation.wrap = true
                explanation.xalign = 0
                explanation.add(cssClass: "caption")
                explanation.add(cssClass: "dim-label")
                labSection.append(child: explanation)
            }

            let buttonLabel: String
            if let user = engine.gitHubAuth.currentUser {
                buttonLabel = "Enable collaboration as @\(user.id)"
            } else {
                buttonLabel = "Enable collaboration"
            }
            let enable = Button(label: buttonLabel)
            enable.add(cssClass: "suggested-action")
            enable.halign = .start
            let labToJoin = storedLabID
            enable.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine?.startCollaboration(joiningLab: labToJoin)
                }
            }
            labSection.append(child: enable)

        case .connecting:
            let row = Box(orientation: .horizontal, spacing: 6)
            row.append(child: Adw.Spinner())
            let label = Label(str: "Connecting\u{2026}")
            label.halign = .start
            label.hexpand = true
            label.add(cssClass: "caption")
            label.add(cssClass: "dim-label")
            row.append(child: label)
            labSection.append(child: row)

        case .joined(let labID):
            let headerRow = Box(orientation: .horizontal, spacing: 10)
            headerRow.append(child: makeLabPictureButton())
            headerRow.append(child: makeLabTitleRow())
            labSection.append(child: headerRow)

            let roleLabel = Label(str: engine.collaboration.isHost ? "You are hosting this lab." : "You joined this lab.")
            roleLabel.halign = .start
            roleLabel.add(cssClass: "caption")
            roleLabel.add(cssClass: "dim-label")
            labSection.append(child: roleLabel)

            if notificationsButton.parent != nil {
                notificationsButton.unparent()
            }
            notificationsButton.halign = .start
            labSection.append(child: notificationsButton)
            refreshNotificationsButton()

            let inviteURL = "\(BackendConfig.inviteLinkBase)\(labID)"
            let inviteFrame = Box(orientation: .vertical, spacing: 4)
            inviteFrame.add(cssClass: "luma-invite-frame")
            inviteFrame.hexpand = true

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

            let copyButton = Button()
            copyButton.hasFrame = false
            copyButton.set(iconName: "edit-copy-symbolic")
            copyButton.tooltipText = "Copy invite link"
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

            let hint = Label(
                str: "Share this link so others can open a new project and join this notebook.")
            hint.halign = .fill
            hint.hexpand = true
            hint.wrap = true
            hint.xalign = 0
            hint.add(cssClass: "caption")
            hint.add(cssClass: "dim-label")
            inviteFrame.append(child: hint)

            let toast = Label(str: "Copied!")
            toast.halign = .start
            toast.add(cssClass: "caption")
            toast.add(cssClass: "accent")
            toast.visible = false
            inviteFrame.append(child: toast)
            copiedToastLabel = toast

            labSection.append(child: inviteFrame)

            let leave = Button(label: "Disconnect from lab")
            leave.halign = .start
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
            let icon = Image(iconName: "dialog-warning-symbolic")
            let errorRow = Box(orientation: .horizontal, spacing: 6)
            errorRow.append(child: icon)
            let label = Label(str: msg)
            label.halign = .start
            label.wrap = true
            label.xalign = 0
            label.hexpand = true
            label.add(cssClass: "warning")
            label.add(cssClass: "caption")
            errorRow.append(child: label)
            labSection.append(child: errorRow)

            let retry = Button(label: "Retry")
            retry.add(cssClass: "suggested-action")
            retry.halign = .start
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
        for (_, widget) in participantWidgets {
            participantsStrip.remove(child: widget)
        }
        participantWidgets.removeAll()

        let sorted = engine.collaboration.members.sorted { a, b in
            if (a.role == .owner) != (b.role == .owner) { return a.role == .owner }
            if (a.presence == .online) != (b.presence == .online) {
                return a.presence == .online
            }
            return a.joinedAt < b.joinedAt
        }
        for member in sorted {
            let widget = makeMemberAvatar(for: member, size: Self.participantAvatarSize)
            participantsStrip.append(child: widget)
            participantWidgets[member.user.id] = widget
        }
    }

    private func addParticipant(_ user: LumaCore.CollaborationSession.UserInfo) {
        refreshParticipants()
    }

    private func removeParticipant(_ userID: String) {
        refreshParticipants()
    }

    private func makeMemberAvatar(
        for member: LumaCore.CollaborationSession.Member,
        size: Int
    ) -> Widget {
        let overlay = Overlay()
        let button = makeAvatarButton(for: member.user, size: size)
        let role = member.role == .owner ? "owner" : "member"
        let presence = member.presence == .online ? "online" : "offline"
        button.tooltipText = "\(member.user.name) · \(role) · \(presence)"
        if member.presence == .offline {
            button.opacity = 0.55
        }
        overlay.set(child: button)

        let dot = Box(orientation: .horizontal, spacing: 0)
        dot.add(cssClass: "luma-member-dot")
        dot.add(cssClass: member.presence == .online ? "online" : "offline")
        dot.halign = .end
        dot.valign = .end
        dot.canTarget = false
        overlay.addOverlay(widget: dot)

        if member.role == .owner {
            let crown = Label(str: "\u{2605}")
            crown.add(cssClass: "luma-member-owner-badge")
            crown.halign = .end
            crown.valign = .start
            crown.canTarget = false
            overlay.addOverlay(widget: crown)
        }

        return overlay
    }

    private func refreshChat() {
        guard let engine else { return }
        chatListBox.removeAll()
        chatTimestamps.removeAll()
        let messages = engine.collaboration.chatMessages
        for message in messages {
            chatListBox.append(child: buildChatRow(for: message))
        }

        if messages.count != lastChatCount {
            lastChatCount = messages.count
            if isPinnedToBottom {
                scrollChatToBottomSoon()
            }
        }

        refreshChatInputState()
    }

    private func appendChatMessage(_ message: LumaCore.CollaborationSession.ChatMessage) {
        chatListBox.append(child: buildChatRow(for: message))

        lastChatCount += 1
        if isPinnedToBottom {
            scrollChatToBottomSoon()
        }
        refreshChatInputState()
    }

    private func buildChatRow(for message: LumaCore.CollaborationSession.ChatMessage) -> ListBoxRow {
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

        let avatar = makeAvatarButton(for: message.sender, size: Self.chatAvatarSize)
        header.append(child: avatar)

        let senderName = message.isLocal
            ? "You"
            : "@\(message.sender.id)"
        let senderLabel = Label(str: senderName)
        senderLabel.halign = .start
        senderLabel.hexpand = true
        senderLabel.add(cssClass: "caption")
        senderLabel.add(cssClass: "dim-label")
        header.append(child: senderLabel)

        let timeLabel = Label(str: RelativeTime.string(from: message.timestamp))
        timeLabel.tooltipText = chatTimeFormatter.string(from: message.timestamp)
        timeLabel.halign = .end
        timeLabel.add(cssClass: "caption")
        timeLabel.add(cssClass: "dim-label")
        chatTimestamps.append((label: timeLabel, date: message.timestamp))
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
        return row
    }

    // MARK: - Avatars

    private func makeAvatar(
        for user: LumaCore.CollaborationSession.UserInfo,
        size: Int
    ) -> Adw.Avatar {
        let displayName = user.name.isEmpty ? "@\(user.id)" : user.name
        let avatar = Adw.Avatar(size: size, text: displayName, showInitials: true)
        avatar.tooltipText = displayName

        loadAvatarImage(into: avatar, user: user, size: size)
        return avatar
    }

    private func makeAvatarButton(
        for user: LumaCore.CollaborationSession.UserInfo,
        size: Int
    ) -> Button {
        let button = Button()
        button.hasFrame = false
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-avatar-button")
        button.tooltipText = user.name.isEmpty ? "@\(user.id)" : user.name

        let avatar = makeAvatar(for: user, size: size)
        avatar.tooltipText = nil
        button.set(child: avatar)

        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openGitHubProfile(for: user)
            }
        }
        return button
    }

    private func loadAvatarImage(
        into avatar: Adw.Avatar,
        user: LumaCore.CollaborationSession.UserInfo,
        size: Int
    ) {
        guard let base = user.avatarURL else { return }
        guard let url = URL(string: "\(base.absoluteString)&s=96") else { return }

        Task { @MainActor [avatar] in
            guard let texture = await AvatarCache.shared.texture(for: url) else { return }
            avatar.set(customImage: texture)
        }
    }

    private func enableBrowserNotifications() {
        guard let engine else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await engine.webPushEnrollmentURL()
                let launcher = UriLauncher(uri: url.absoluteString)
                let parentWindow: Gtk.WindowRef?
                if let rootPtr = self.widget.root?.ptr {
                    parentWindow = Gtk.WindowRef(raw: rootPtr)
                } else {
                    parentWindow = nil
                }
                launcher.launch(parent: parentWindow, cancellable: nil, callback: nil, userData: nil)
            } catch {
                print("push enrollment failed: \(error)")
            }
        }
    }

    private func openGitHubProfile(for user: LumaCore.CollaborationSession.UserInfo) {
        let urlString = "https://github.com/\(user.id)"
        let launcher = UriLauncher(uri: urlString)
        let parentWindow: Gtk.WindowRef?
        if let rootPtr = widget.root?.ptr {
            parentWindow = Gtk.WindowRef(raw: rootPtr)
        } else {
            parentWindow = nil
        }
        launcher.launch(parent: parentWindow, cancellable: nil, callback: nil, userData: nil)
    }

    // MARK: - Scroll / input

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
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)\u{2026}\(suffix)"
    }

    private func clearChildren(of container: Box) {
        var child = container.firstChild
        while let current = child {
            child = current.nextSibling
            container.remove(child: current)
        }
    }
}

@MainActor
private final class LabPictureContext {
    let engine: Engine
    init(engine: Engine) { self.engine = engine }
}

private let labPicturePathThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let pathString: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let ctx = Unmanaged<LabPictureContext>.fromOpaque(ptr).takeRetainedValue()
        guard let pathString else { return }
        let url = URL(fileURLWithPath: pathString)
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "png": contentType = "image/png"
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "webp": contentType = "image/webp"
        case "gif": contentType = "image/gif"
        default: contentType = "image/png"
        }
        let engine = ctx.engine
        Task { @MainActor in
            await engine.collaboration.setLabPicture(data, contentType: contentType)
        }
    }
}
