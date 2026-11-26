import Adw
import CGraphene
import CGtk
import Foundation
import Gtk
import LumaCore
import Observation
import SwiftyPharo

@MainActor
final class PharoObjectChatPage {
    static var showSubject: ((ObjectChatSubjectPlace) -> Void)?
    private static var openPages: [UUID: Int] = [:]

    let widget: Box
    var onDiscarded: () -> Void = {}

    private let engine: Engine
    let chatID: UUID
    private let onSelect: (PharoObject) -> Void

    private let titleLabel = Label(str: "")
    private let aboutLabel = Label(str: "")
    private let editorsSlot = Box(orientation: .horizontal, spacing: 0)
    private let showSubjectButton = Button()
    private let renameButton = Button()
    private let deleteButton = Button()
    private let transcript = ConversationTranscript()
    private let runsWithoutAskingNotice = Box(orientation: .horizontal, spacing: 6)
    private let removedInLabNotice = Box(orientation: .vertical, spacing: 4)
    private let problemNotices = Box(orientation: .vertical, spacing: 6)
    private var shownProblems: [UUID] = []
    private var inputBar: ConversationInputBar!

    private var rows: [UUID: ConversationMessageRow] = [:]
    private var answers: [UUID: Answer] = [:]
    private var cards: [UUID: PharoChatToolCallCard] = [:]
    private var shownMessageIDs: [UUID] = []
    private var shownEditors: [String]?
    private var streaming: (row: ConversationMessageRow, answer: Answer)?
    private var scrolledFor: ScrollMark?
    private var failure: String?
    private var isDeleted = false
    private var isMapped = false
    private var watchedScrollers: Set<UnsafeMutableRawPointer> = []
    private var awaitsLayout = false
    private var isRemovedInLab = false
    private var subject: ObjectChatSubjectPlace?
    private let modelPicker: ObjectChatModelPicker
    private let answerNotice = Box(orientation: .horizontal, spacing: 6)
    private let answerNoticeLabel = Label(str: "")
    private var answerUnavailableReason: String?
    private var checkedChoice: ObjectChatModelChoice?
    private var answerCheck: Task<Void, Never>?
    private var checkedSubject: ObjectChatSubjectPlace?
    private var subjectUnavailableReason: String?
    private var subjectCheck: Task<Void, Never>?

    private struct Answer: Equatable {
        var body: String
        var callIDs: [UUID]
        var error: String?
        var unsent: String?
        var isRemovedInLab = false
    }

    private struct ScrollMark: Equatable {
        let messageCount: Int
        let replyText: String?
        let toolCallCount: Int
    }

    enum Form {
        case column
        case panel
    }

    init(engine: Engine, chatID: UUID, form: Form, onSelect: @escaping (PharoObject) -> Void) {
        self.engine = engine
        self.chatID = chatID
        self.onSelect = onSelect
        Self.openPages[chatID, default: 0] += 1

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        modelPicker = ObjectChatModelPicker(engine: engine, chatID: chatID)

        inputBar = ConversationInputBar(
            primary: askAction,
            secondary: postAction(hasCompany: false),
            onStop: { [weak self] in
                guard let self else { return }
                self.chats.cancel(self.chatID)
            })

        if form == .column {
            widget.append(child: header())
            widget.append(child: Separator(orientation: .horizontal))
        }
        widget.append(child: makeRemovedInLabNotice())
        problemNotices.marginStart = 12
        problemNotices.marginEnd = 12
        problemNotices.marginTop = 6
        widget.append(child: problemNotices)
        widget.append(child: transcript.widget)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: makeRunsWithoutAskingNotice())
        widget.append(child: inputBar.widget)
        modelPicker.onSetUp = { [weak self] in self?.setUpProvider() }
        inputBar.accessory.append(child: modelPicker.widget)
        inputBar.accessory.append(child: makeAnswerNotice())

        widget.onMap { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMapped = true
                self.watchScrolling()
                self.markReadIfShown()
            }
        }
        widget.onUnmap { [weak self] _ in
            MainActor.assumeIsolated { self?.isMapped = false }
        }

        follow()
    }

    private func markReadIfShown() {
        if isOnScreen {
            chats.markRead(chatID)
        } else if isMapped, widget.width == 0, !awaitsLayout {
            awaitsLayout = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.awaitsLayout = false
                self.markReadIfShown()
            }
        }
    }

    private var isOnScreen: Bool {
        guard isMapped else { return false }
        for scroller in scrollingAncestors {
            var bounds = graphene_rect_t()
            guard gtk_widget_compute_bounds(widget.widget_ptr, scroller, &bounds) != 0, bounds.size.width > 0 else { return false }
            let start = max(Double(bounds.origin.x), 0)
            let end = min(Double(bounds.origin.x + bounds.size.width), Double(gtk_widget_get_width(scroller)))
            if (end - start) / Double(bounds.size.width) < 0.5 { return false }
        }
        return true
    }

    private var scrollingAncestors: [UnsafeMutablePointer<GtkWidget>] {
        var scrollers: [UnsafeMutablePointer<GtkWidget>] = []
        var next = gtk_widget_get_ancestor(widget.widget_ptr, gtk_scrolled_window_get_type())
        while let scroller = next {
            scrollers.append(scroller)
            next = gtk_widget_get_parent(scroller).flatMap { gtk_widget_get_ancestor($0, gtk_scrolled_window_get_type()) }
        }
        return scrollers
    }

    private func watchScrolling() {
        for scroller in scrollingAncestors where watchedScrollers.insert(UnsafeMutableRawPointer(scroller)).inserted {
            let adjustment = ScrolledWindowRef(raw: UnsafeMutableRawPointer(scroller)).hadjustment
            adjustment?.onValueChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.markReadIfShown() }
            }
            adjustment?.onChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.markReadIfShown() }
            }
        }
    }

    deinit {
        let (engine, chatID) = (self.engine, self.chatID)
        Task { @MainActor in Self.closed(chatID, in: engine) }
    }

    private static func closed(_ chatID: UUID, in engine: Engine) {
        openPages[chatID, default: 1] -= 1
        guard openPages[chatID] == 0 else { return }
        openPages[chatID] = nil
        guard engine.objectChats.isDraft(chatID) else { return }
        Task { await engine.objectChats.discard(chatID) }
    }

    private var askAction: ConversationInputBar.Action {
        ConversationInputBar.Action(iconName: "starred-symbolic", tooltip: "Ask the Assistant", unavailableReason: answerUnavailableReason) {
            [weak self] in self?.ask()
        }
    }

    private func makeAnswerNotice() -> Box {
        let icon = Gtk.Image(iconName: "dialog-information-symbolic")
        icon.add(cssClass: "dim-label")
        answerNotice.append(child: icon)
        answerNoticeLabel.add(cssClass: "caption")
        answerNoticeLabel.add(cssClass: "dim-label")
        answerNoticeLabel.xalign = 0
        answerNoticeLabel.wrap = true
        answerNoticeLabel.lines = 2
        answerNoticeLabel.ellipsize = .end
        answerNoticeLabel.hexpand = true
        answerNotice.append(child: answerNoticeLabel)
        let setUp = Button(label: "Set Up…")
        setUp.add(cssClass: "flat")
        setUp.add(cssClass: "caption")
        setUp.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.setUpProvider() }
        }
        answerNotice.append(child: setUp)
        answerNotice.hexpand = true
        answerNotice.visible = false
        return answerNotice
    }

    private func setUpProvider() {
        ObjectChatProviderSetupDialog.present(engine: engine, chatID: chatID, from: widget) { [weak self] in
            self?.checkAnswer()
        }
    }

    private func checkAnswer() {
        answerCheck?.cancel()
        answerCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            let reason = await self.chats.answerUnavailableReason(in: self.chatID)
            guard !Task.isCancelled else { return }
            self.answerUnavailableReason = reason
            self.answerNoticeLabel.label = reason ?? ""
            self.answerNotice.visible = reason != nil
            self.offerActions()
        }
    }

    private func offerActions() {
        inputBar.offer(
            primary: hasCompany ? postAction(hasCompany: true) : askAction,
            secondary: hasCompany ? askAction : postAction(hasCompany: false))
    }

    private func ask() {
        let text = inputBar.draft
        guard !text.isEmpty else { return }
        inputBar.clearDraft()
        failure = nil
        refreshInputBar()
        Task { @MainActor in
            do {
                try await chats.ask(text, in: chatID)
            } catch {
                if inputBar.draft.isEmpty {
                    inputBar.restore(draft: text)
                }
                failure = error.localizedDescription
                refreshInputBar()
            }
        }
    }

    private func postAction(hasCompany: Bool) -> ConversationInputBar.Action {
        ConversationInputBar.Action(
            iconName: "mail-send-symbolic",
            tooltip: hasCompany ? "Send" : "Send without asking the assistant"
        ) { [weak self] in self?.post() }
    }

    private func post() {
        let text = inputBar.draft
        guard !text.isEmpty else { return }
        do {
            try chats.post(text, in: chatID)
            inputBar.clearDraft()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refreshInputBar()
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private func header() -> Box {
        let header = Box(orientation: .vertical, spacing: 4)
        header.marginStart = 12
        header.marginEnd = 12
        header.marginTop = 8
        header.marginBottom = 8

        let top = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: "chat-message-new-symbolic")
        icon.pixelSize = 14
        icon.add(cssClass: "dim-label")
        top.append(child: icon)

        titleLabel.add(cssClass: "heading")
        titleLabel.halign = .start
        titleLabel.xalign = 0
        titleLabel.ellipsize = .end
        titleLabel.singleLineMode = true
        top.append(child: titleLabel)

        editorsSlot.hexpand = true
        top.append(child: editorsSlot)

        let subjectIcon = Gtk.Image(iconName: "find-location-symbolic")
        subjectIcon.pixelSize = 12
        showSubjectButton.set(child: subjectIcon)
        showSubjectButton.add(cssClass: "flat")
        showSubjectButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.showSubject() }
        }
        top.append(child: showSubjectButton)

        let renameIcon = Gtk.Image(iconName: "document-edit-symbolic")
        renameIcon.pixelSize = 12
        renameButton.set(child: renameIcon)
        renameButton.add(cssClass: "flat")
        renameButton.tooltipText = "Rename chat"
        renameButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRenaming() }
        }
        top.append(child: renameButton)

        let deleteIcon = Gtk.Image(iconName: "user-trash-symbolic")
        deleteIcon.pixelSize = 12
        deleteButton.set(child: deleteIcon)
        deleteButton.add(cssClass: "flat")
        deleteButton.add(cssClass: "luma-menu-destructive")
        deleteButton.tooltipText = "Delete chat"
        deleteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.confirmDeletingChat() }
        }
        top.append(child: deleteButton)
        header.append(child: top)

        aboutLabel.add(cssClass: "caption")
        aboutLabel.add(cssClass: "dim-label")
        aboutLabel.xalign = 0
        aboutLabel.wrap = true
        aboutLabel.lines = 2
        aboutLabel.ellipsize = .end
        header.append(child: aboutLabel)

        return header
    }

    private func showSubject() {
        guard let chat = chats.chat(withID: chatID) else { return }
        Self.showSubject?(chats.subject(of: chat))
    }

    private func beginRenaming() {
        let title = chats.chat(withID: chatID).map(chats.displayTitle(of:)) ?? ""
        RenamePopover.present(heading: "Rename chat", title: title, at: renameButton) { [weak self] title in
            self?.rename(to: title)
        }
    }

    private func rename(to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        chats.rename(chatID, to: title)
    }

    private func confirmDeletingChat() {
        ConfirmationPopover.present(heading: "Delete this chat?", destructiveLabel: "Delete", at: deleteButton) { [weak self] in
            self?.deleteChat()
        }
    }

    private func deleteChat() {
        Task { @MainActor in
            do {
                try await chats.delete(chatID)
            } catch {
                failure = error.localizedDescription
                refreshInputBar()
            }
        }
    }

    private func makeRemovedInLabNotice() -> Box {
        removedInLabNotice.marginStart = 12
        removedInLabNotice.marginEnd = 12
        removedInLabNotice.marginTop = 6
        removedInLabNotice.visible = false

        let statement = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: "dialog-warning-symbolic")
        icon.add(cssClass: "warning")
        icon.valign = .start
        statement.append(child: icon)

        let text = Label(str: "This chat was deleted in the lab. What you wrote here was not sent.")
        text.add(cssClass: "caption")
        text.xalign = 0
        text.wrap = true
        text.hexpand = true
        statement.append(child: text)
        removedInLabNotice.append(child: statement)

        let actions = Box(orientation: .horizontal, spacing: 6)
        actions.halign = .start

        let copy = Button(label: "Copy What I Wrote")
        copy.add(cssClass: "flat")
        copy.add(cssClass: "caption")
        copy.onClicked { [weak self] clicked in
            MainActor.assumeIsolated {
                guard let self else { return }
                clicked.clipboard.set(text: self.unsentText)
            }
        }
        actions.append(child: copy)

        let deleteHere = Button(label: "Delete Here")
        deleteHere.add(cssClass: "flat")
        deleteHere.add(cssClass: "luma-menu-destructive")
        deleteHere.add(cssClass: "caption")
        deleteHere.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.deleteChat() }
        }
        actions.append(child: deleteHere)
        removedInLabNotice.append(child: actions)
        return removedInLabNotice
    }

    private var unsentText: String {
        chats.thread(of: chatID).messages.filter { chats.unsent[$0.id] != nil }.map(\.bodyMarkdown).joined(separator: "\n\n")
    }

    private func makeRunsWithoutAskingNotice() -> Box {
        runsWithoutAskingNotice.marginStart = 12
        runsWithoutAskingNotice.marginEnd = 12
        runsWithoutAskingNotice.marginTop = 6

        let icon = Gtk.Image(iconName: "dialog-warning-symbolic")
        icon.add(cssClass: "warning")
        runsWithoutAskingNotice.append(child: icon)

        let text = Label(str: "The assistant's expressions run without asking.")
        text.add(cssClass: "caption")
        text.add(cssClass: "dim-label")
        text.xalign = 0
        text.wrap = true
        text.hexpand = true
        runsWithoutAskingNotice.append(child: text)

        let askFirst = Button(label: "Ask First")
        askFirst.add(cssClass: "flat")
        askFirst.add(cssClass: "caption")
        askFirst.valign = .center
        askFirst.onClicked { _ in
            MainActor.assumeIsolated { ObjectChatRunSetting.shared.runsWithoutAsking = false }
        }
        runsWithoutAskingNotice.append(child: askFirst)
        return runsWithoutAskingNotice
    }

    private func follow() {
        var choice: ObjectChatModelChoice?
        let (chat, thread, runsWithoutAsking, _, discarded): (ObjectChat?, ObjectChats.Thread, Bool, Bool, Bool) = withObservationTracking {
            let thread = chats.thread(of: chatID)
            isRemovedInLab = chats.removedInLab.contains(chatID)
            _ = chats.unsent
            _ = chats.problems
            _ = thread.toolCalls.map(chats.hold(on:))
            let chat = chats.chat(withID: chatID)
            subject = chat.map(chats.subject(of:))
            choice = chats.modelChoice(in: chatID)
            return (chat, thread, ObjectChatRunSetting.shared.runsWithoutAsking, self.hasCompany, chats.wasDiscarded(chatID) || chats.wasDeletedHere(chatID))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard let chat else {
            if discarded {
                onDiscarded()
            } else {
                showDeleted()
            }
            return
        }
        show(chat)
        show(thread, of: chat)
        runsWithoutAskingNotice.visible = runsWithoutAsking
        removedInLabNotice.visible = isRemovedInLab
        showProblems()
        if choice != checkedChoice {
            checkedChoice = choice
            checkAnswer()
        }
        offerActions()
        if isMapped {
            markReadIfShown()
        }
    }

    private func showProblems() {
        let problems = chats.problems.filter { $0.chatID == chatID && $0.messageID == nil }
        guard problems.map(\.id) != shownProblems else { return }
        shownProblems = problems.map(\.id)
        while let child = problemNotices.firstChild {
            problemNotices.remove(child: child)
        }
        for problem in problems {
            problemNotices.append(child: ObjectChatProblemNotice.make(problem, chats: chats, namesChat: false))
        }
        problemNotices.visible = !problems.isEmpty
    }

    private var hasCompany: Bool {
        guard engine.associatedLabID != nil else { return false }
        let members = engine.collaboration.members
        return members.isEmpty || members.contains { !engine.collaboration.isSelf($0.user.id) }
    }

    private func showDeleted() {
        guard !isDeleted else { return }
        isDeleted = true
        while let child = widget.firstChild {
            widget.remove(child: child)
        }
        let page = Adw.StatusPage()
        page.iconName = "chat-message-new-symbolic"
        page.title = "This chat was deleted"
        page.vexpand = true
        widget.append(child: page)
    }

    private func show(_ chat: ObjectChat) {
        titleLabel.label = chats.displayTitle(of: chat)
        deleteButton.visible = chats.canDelete(chat.id)
        renameButton.visible = chats.canRename(chat.id)
        aboutLabel.label = about(chat)
        if subject != checkedSubject {
            checkedSubject = subject
            checkSubject()
        }
        showSubjectAvailability()
        let editors = chat.editors.map(\.id)
        if editors != shownEditors {
            shownEditors = editors
            while let child = editorsSlot.firstChild {
                editorsSlot.remove(child: child)
            }
            if !chat.editors.isEmpty {
                editorsSlot.append(child: AuthorAvatarStack.make(chat.editors, size: 18))
            }
        }
    }

    private func checkSubject() {
        subjectCheck?.cancel()
        subjectUnavailableReason = nil
        guard case .instruction(let place) = subject else { return }
        subjectCheck = Task { @MainActor [weak self] in
            guard let reason = await self?.engine.disassemblyUnavailableReason(at: place), !Task.isCancelled, let self else { return }
            self.subjectUnavailableReason = reason
            self.showSubjectAvailability()
        }
    }

    private func showSubjectAvailability() {
        let unavailable = subject.flatMap(unavailableReason(of:))
        showSubjectButton.sensitive = unavailable == nil
        showSubjectButton.tooltipText = unavailable ?? "Show Subject"
    }

    private func unavailableReason(of subject: ObjectChatSubjectPlace) -> String? {
        switch subject {
        case .instruction(let place):
            place.unavailableReason ?? subjectUnavailableReason
        case .project, .object:
            nil
        }
    }

    private func about(_ chat: ObjectChat) -> String {
        switch (subject, chat.subject) {
        case (.instruction(let place), _):
            "About the instruction at \(place.anchor.displayString) in \(place.sessionName ?? "a session not in this project")"
        case (_, .object(_, let label, _, _, let printString, _)):
            "About \(printString), from \(label)"
        case (_, .project), (_, .instruction):
            "About the project"
        }
    }

    private func show(_ thread: ObjectChats.Thread, of chat: ObjectChat) {
        let messageIDs = thread.messages.map(\.id)
        if messageIDs != shownMessageIDs {
            relist(thread.messages)
        }
        for message in thread.messages {
            refresh(message, in: thread)
        }
        showStreaming(thread, of: chat)
        refreshInputBar(isSending: thread.replyText != nil)

        let mark = ScrollMark(messageCount: thread.messages.count, replyText: thread.replyText, toolCallCount: thread.toolCalls.count)
        if mark != scrolledFor {
            scrolledFor = mark
            transcript.scrollToBottom()
        }
    }

    private func relist(_ messages: [ObjectChatMessage]) {
        for id in shownMessageIDs {
            if let row = rows[id] {
                transcript.remove(row.widget)
            }
        }
        let present = Set(messages.map(\.id))
        rows = rows.filter { present.contains($0.key) }
        answers = answers.filter { present.contains($0.key) }
        for message in messages {
            transcript.append((rows[message.id] ?? makeRow(message)).widget)
        }
        shownMessageIDs = messages.map(\.id)
        if let streaming {
            transcript.remove(streaming.row.widget)
            transcript.append(streaming.row.widget)
        }
    }

    private func makeRow(_ message: ObjectChatMessage) -> ConversationMessageRow {
        let row: ConversationMessageRow
        switch message.role {
        case .user:
            row = ConversationMessageRow(message: message, isMine: chats.isMine(message))
            let messageID = message.id
            row.offerEditing(
                onEdit: { [weak self] in self?.beginEditing(messageID) },
                onDelete: { [weak self] in self?.confirmDeleting(messageID) },
                canEdit: { [weak self] in self?.permits(messageID) { $0.canEdit($1) } ?? false },
                canDelete: { [weak self] in self?.permits(messageID) { $0.canRemove($1) } ?? false })
        case .assistant:
            row = ConversationMessageRow(message: message, isMine: false, content: Box(orientation: .vertical, spacing: 6))
        }
        rows[message.id] = row
        return row
    }

    private func permits(_ messageID: UUID, _ right: (ObjectChats, ObjectChatMessage) -> Bool) -> Bool {
        guard let message = chats.thread(of: chatID).messages.first(where: { $0.id == messageID }) else { return false }
        return right(chats, message)
    }

    private func beginEditing(_ messageID: UUID) {
        guard let message = chats.thread(of: chatID).messages.first(where: { $0.id == messageID }), let row = rows[messageID] else {
            return
        }
        row.edit(message.bodyMarkdown) { [weak self] body in
            self?.commitEdit(of: message, to: body)
        }
    }

    private func commitEdit(of message: ObjectChatMessage, to body: String) {
        guard !body.isEmpty, body != message.bodyMarkdown else { return }
        do {
            try chats.edit(message.id, in: chatID, to: body)
        } catch {
            failure = error.localizedDescription
            refreshInputBar()
        }
    }

    private func confirmDeleting(_ messageID: UUID) {
        guard let row = rows[messageID] else { return }
        ConfirmationPopover.present(heading: "Delete message?", destructiveLabel: "Delete", at: row.content) { [weak self] in
            self?.delete(messageID)
        }
    }

    private func delete(_ messageID: UUID) {
        do {
            try chats.remove(messageID, in: chatID)
        } catch {
            failure = error.localizedDescription
            refreshInputBar()
        }
    }

    private func refresh(_ message: ObjectChatMessage, in thread: ObjectChats.Thread) {
        guard let row = rows[message.id] else { return }
        let calls = thread.toolCalls.filter { $0.messageID == message.id }
        let answer = Answer(
            body: message.bodyMarkdown, callIDs: calls.map(\.id), error: message.error, unsent: chats.unsent[message.id],
            isRemovedInLab: isRemovedInLab)
        if answers[message.id] != answer {
            answers[message.id] = answer
            switch message.role {
            case .user:
                row.show(markdown: message.bodyMarkdown)
                row.show(footer: answer.unsent.map { unsentFooter(for: message, because: $0) })
                row.content.opacity = answer.unsent == nil ? 1 : 0.55
            case .assistant:
                fill(row.content, with: answer.body, calls: calls, error: answer.error)
            }
        }
        update(calls)
    }

    private func unsentFooter(for message: ObjectChatMessage, because reason: String) -> Box {
        let footer = Box(orientation: .horizontal, spacing: 6)
        footer.marginTop = 2

        let icon = Gtk.Image(iconName: "dialog-warning-symbolic")
        icon.add(cssClass: "error")
        icon.valign = .start
        footer.append(child: icon)

        let text = Label(str: "Not sent: \(reason)")
        text.add(cssClass: "caption")
        text.add(cssClass: "dim-label")
        text.xalign = 0
        text.wrap = true
        text.selectable = true
        text.hexpand = true
        footer.append(child: text)

        let messageID = message.id
        if !isRemovedInLab {
            let again = Button(label: "Send Again")
            again.add(cssClass: "flat")
            again.add(cssClass: "caption")
            again.valign = .start
            again.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.chats.resend(messageID, in: self.chatID)
                }
            }
            footer.append(child: again)
        }

        if chats.canRemove(message) {
            let delete = Button(label: "Delete")
            delete.add(cssClass: "flat")
            delete.add(cssClass: "caption")
            delete.add(cssClass: "luma-menu-destructive")
            delete.valign = .start
            delete.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.confirmDeleting(messageID) }
            }
            footer.append(child: delete)
        }
        return footer
    }

    private func fill(_ content: Box, with text: String, calls: [ObjectChatToolCall], error: String?) {
        while let child = content.firstChild {
            content.remove(child: child)
        }
        for segment in PharoChatSegment.split(text, around: calls) {
            switch segment {
            case .text(let text) where text.isEmpty && error != nil:
                continue
            case .text(let text):
                content.append(child: ConversationMessageRow.bubble(markdown: text))
            case .call(let call):
                let card = card(for: call).widget
                if card.parent != nil {
                    card.unparent()
                }
                content.append(child: card)
            }
        }
        if let error {
            let label = Label(str: error)
            label.add(cssClass: "caption")
            label.add(cssClass: "error")
            label.xalign = 0
            label.wrap = true
            label.selectable = true
            content.append(child: label)
        }
    }

    private func card(for call: ObjectChatToolCall) -> PharoChatToolCallCard {
        if let card = cards[call.id] {
            return card
        }
        let card = PharoChatToolCallCard(call: call, engine: engine, onSelect: onSelect)
        cards[call.id] = card
        return card
    }

    private func update(_ calls: [ObjectChatToolCall]) {
        for call in calls {
            cards[call.id]?.update(call)
        }
    }

    private func showStreaming(_ thread: ObjectChats.Thread, of chat: ObjectChat) {
        guard let text = thread.replyText else {
            if let streaming {
                transcript.remove(streaming.row.widget)
                self.streaming = nil
            }
            return
        }
        let answered = Set(thread.messages.map(\.id))
        let calls = thread.toolCalls.filter { !answered.contains($0.messageID) }
        let answer = Answer(body: text, callIDs: calls.map(\.id), error: nil)
        let row: ConversationMessageRow
        if let streaming {
            row = streaming.row
            guard streaming.answer != answer else {
                update(calls)
                return
            }
        } else {
            let placeholder = ObjectChatMessage(
                chatID: chatID,
                index: -1,
                role: .assistant,
                author: nil,
                bodyMarkdown: "",
                modelID: chats.modelChoice(in: chatID).modelID)
            row = ConversationMessageRow(message: placeholder, isMine: false, content: Box(orientation: .vertical, spacing: 6))
            transcript.append(row.widget)
        }
        streaming = (row, answer)
        fill(row.content, with: text, calls: calls, error: nil)
        update(calls)
    }

    private func refreshInputBar() {
        refreshInputBar(isSending: chats.thread(of: chatID).replyText != nil)
    }

    private func refreshInputBar(isSending: Bool) {
        inputBar.show(isSending: isSending, failure: failure)
    }

}

private enum PharoChatSegment {
    case text(String)
    case call(ObjectChatToolCall)

    static func split(_ text: String, around calls: [ObjectChatToolCall]) -> [PharoChatSegment] {
        var segments: [PharoChatSegment] = []
        var cursor = 0
        for call in calls.sorted(by: { ($0.offset, $0.index) < ($1.offset, $1.index) }) {
            let end = min(call.offset, text.count)
            segments += piece(of: text, from: cursor, to: end)
            cursor = max(cursor, end)
            segments.append(.call(call))
        }
        segments += piece(of: text, from: cursor, to: text.count)
        return segments.isEmpty ? [.text("")] : segments
    }

    private static func piece(of text: String, from start: Int, to end: Int) -> [PharoChatSegment] {
        guard end > start else { return [] }
        let piece = String(text.dropFirst(start).prefix(end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        return piece.isEmpty ? [] : [.text(piece)]
    }
}
