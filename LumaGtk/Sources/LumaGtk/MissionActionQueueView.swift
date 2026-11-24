import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class MissionActionQueueView {
    let widget: Box

    private weak var engine: Engine?
    private let parentWindow: Gtk.Window
    private let countLabel: Label
    private let listScroll: ScrolledWindow
    private let listBox: Box
    private let placeholder: Label
    private let bodyContainer: Box

    private var cardsByActionID: [UUID: ActionCard] = [:]
    private var inputCardsByActionID: [UUID: RequestUserInputCard] = [:]
    private var chatCallCards: [UUID: ChatCallCard] = [:]

    var onOpenChat: (UUID) -> Void = { _ in }

    init(engine: Engine?, parentWindow: Gtk.Window) {
        self.engine = engine
        self.parentWindow = parentWindow

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        let header = Box(orientation: .horizontal, spacing: 8)
        header.marginStart = 16
        header.marginEnd = 16
        header.marginTop = 14
        header.marginBottom = 6

        let icon = Gtk.Image(iconName: "mail-mark-important-symbolic")
        icon.pixelSize = 16
        icon.add(cssClass: "warning")
        header.append(child: icon)

        let title = Label(str: "Action Queue")
        title.halign = .start
        title.hexpand = true
        title.add(cssClass: "heading")
        header.append(child: title)

        countLabel = Label(str: "0 pending")
        countLabel.add(cssClass: "dim-label")
        countLabel.add(cssClass: "caption")
        header.append(child: countLabel)
        widget.append(child: header)

        placeholder = Label(str: "No actions awaiting approval.")
        placeholder.halign = .start
        placeholder.add(cssClass: "dim-label")
        placeholder.marginStart = 16
        placeholder.marginEnd = 16
        placeholder.marginBottom = 12

        listBox = Box(orientation: .vertical, spacing: 8)
        listBox.marginStart = 16
        listBox.marginEnd = 16
        listBox.marginBottom = 12
        listBox.hexpand = true

        listScroll = ScrolledWindow()
        listScroll.hexpand = true
        listScroll.vexpand = true
        listScroll.set(child: listBox)

        bodyContainer = Box(orientation: .vertical, spacing: 0)
        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        widget.append(child: bodyContainer)
    }

    func update(actions: [MissionAction], chatCalls: [ObjectChatToolCall]) {
        countLabel.label = "\(actions.count + chatCalls.count) pending"

        var seen: Set<UUID> = []
        var lastWidget: Widget? = nil

        for action in actions {
            seen.insert(action.id)
            if action.toolName == MissionTools.requestUserInputToolName {
                if let card = inputCardsByActionID[action.id] {
                    card.update(action: action)
                    lastWidget = card.widget
                } else {
                    let card = RequestUserInputCard(
                        action: action,
                        onSubmit: { [weak self] answer in
                            guard let self else { return }
                            self.engine?.submitUserInputResponse(
                                actionID: action.id,
                                answer: answer
                            )
                        }
                    )
                    inputCardsByActionID[action.id] = card
                    if let last = lastWidget {
                        listBox.insertChildAfter(child: card.widget, sibling: last)
                    } else {
                        listBox.prepend(child: card.widget)
                    }
                    lastWidget = card.widget
                }
            } else {
                if let card = cardsByActionID[action.id] {
                    card.update(action: action)
                    lastWidget = card.widget
                } else {
                    let card = ActionCard(
                        action: action,
                        engine: engine,
                        onApprove: { [weak self] id in
                            guard let self, let engine = self.engine else { return }
                            Task { @MainActor in
                                await engine.approveMissionAction(actionID: id)
                            }
                        },
                        onReject: { [weak self] id, name in
                            self?.presentRejectDialog(actionID: id, toolName: name)
                        }
                    )
                    cardsByActionID[action.id] = card
                    if let last = lastWidget {
                        listBox.insertChildAfter(child: card.widget, sibling: last)
                    } else {
                        listBox.prepend(child: card.widget)
                    }
                    lastWidget = card.widget
                }
            }
        }

        if let engine {
            for call in chatCalls {
                seen.insert(call.id)
                let card: ChatCallCard
                if let existing = chatCallCards[call.id] {
                    card = existing
                    card.update(call)
                } else {
                    card = ChatCallCard(call: call, engine: engine) { [weak self] chatID in self?.onOpenChat(chatID) }
                    chatCallCards[call.id] = card
                    if let last = lastWidget {
                        listBox.insertChildAfter(child: card.widget, sibling: last)
                    } else {
                        listBox.prepend(child: card.widget)
                    }
                }
                lastWidget = card.widget
            }
        }

        for (id, card) in chatCallCards where !seen.contains(id) {
            if card.widget.parent != nil { listBox.remove(child: card.widget) }
            chatCallCards.removeValue(forKey: id)
        }
        for (id, card) in cardsByActionID where !seen.contains(id) {
            if card.widget.parent != nil { listBox.remove(child: card.widget) }
            cardsByActionID.removeValue(forKey: id)
        }
        for (id, card) in inputCardsByActionID where !seen.contains(id) {
            if card.widget.parent != nil { listBox.remove(child: card.widget) }
            inputCardsByActionID.removeValue(forKey: id)
        }

        while let child = bodyContainer.firstChild {
            bodyContainer.remove(child: child)
        }
        if actions.isEmpty && chatCalls.isEmpty {
            bodyContainer.append(child: placeholder)
        } else {
            bodyContainer.append(child: listScroll)
        }
    }

    private func presentRejectDialog(actionID: UUID, toolName: String) {
        RejectionDialog.present(
            heading: "Reject action?",
            body: "Tell the agent why you rejected \(toolName). This signal can help it adjust.",
            parent: parentWindow
        ) { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                await self.engine?.rejectMissionAction(
                    actionID: actionID,
                    reason: reason
                )
            }
        }
    }
}

@MainActor
private final class ActionCard {
    let widget: Box

    private let toolNameLabel: Label
    private let timeLabel: Label
    private let argsLabel: Label
    private let argsContainer: Box
    private let codeHost: Box
    private var codeEditor: CodeEditor?
    private let rationaleLabel: Label
    private let decision: MissionActionDecision
    private weak var engine: Engine?

    init(
        action: MissionAction,
        engine: Engine?,
        onApprove: @escaping (UUID) -> Void,
        onReject: @escaping (UUID, String) -> Void
    ) {
        self.engine = engine

        widget = Box(orientation: .vertical, spacing: 6)
        widget.add(cssClass: "card")
        widget.add(cssClass: "luma-mission-queue-card")

        let inner = Box(orientation: .vertical, spacing: 6)
        inner.marginStart = 12
        inner.marginEnd = 12
        inner.marginTop = 10
        inner.marginBottom = 10
        widget.append(child: inner)

        let header = Box(orientation: .horizontal, spacing: 8)
        let icon = Gtk.Image(iconName: "applications-engineering-symbolic")
        icon.pixelSize = 14
        header.append(child: icon)
        toolNameLabel = Label(str: action.toolName)
        toolNameLabel.halign = .start
        toolNameLabel.hexpand = true
        toolNameLabel.add(cssClass: "heading")
        toolNameLabel.add(cssClass: "monospace")
        toolNameLabel.add(cssClass: "caption")
        header.append(child: toolNameLabel)
        timeLabel = Label(str: "")
        timeLabel.add(cssClass: "dim-label")
        timeLabel.add(cssClass: "caption")
        header.append(child: timeLabel)
        inner.append(child: header)

        codeHost = Box(orientation: .vertical, spacing: 0)
        codeHost.setSizeRequest(width: -1, height: 200)
        codeHost.visible = false
        inner.append(child: codeHost)

        argsContainer = Box(orientation: .vertical, spacing: 0)
        argsLabel = Label(str: "")
        argsLabel.halign = .fill
        argsLabel.xalign = 0
        argsLabel.wrap = true
        argsLabel.selectable = true
        argsLabel.add(cssClass: "monospace")
        argsLabel.add(cssClass: "caption")
        argsLabel.add(cssClass: "luma-mission-code")
        argsContainer.append(child: argsLabel)
        inner.append(child: argsContainer)

        rationaleLabel = Label(str: "")
        rationaleLabel.halign = .fill
        rationaleLabel.xalign = 0
        rationaleLabel.wrap = true
        rationaleLabel.selectable = true
        rationaleLabel.add(cssClass: "dim-label")
        rationaleLabel.visible = false
        inner.append(child: rationaleLabel)

        decision = MissionActionDecision(
            action: action,
            engine: engine,
            onApprove: { onApprove(action.id) },
            onReject: { onReject(action.id, action.toolName) }
        )
        inner.append(child: decision.widget)

        update(action: action)
    }

    func update(action: MissionAction) {
        decision.update(action: action)
        toolNameLabel.label = action.toolName
        timeLabel.label = RelativeTime.string(from: action.requestedAt)

        let parsed = parsedArgs(action.argsJSON)
        applyCodeAttachment(toolName: action.toolName, args: parsed)

        let remaining = jsonWithoutCodeField(toolName: action.toolName, args: parsed)
        if let remaining {
            argsLabel.label = remaining
            argsContainer.visible = true
        } else {
            argsContainer.visible = false
        }

        if let rationale = action.rationale, !rationale.isEmpty {
            rationaleLabel.label = rationale
            rationaleLabel.visible = true
        } else {
            rationaleLabel.visible = false
        }
    }

    private func applyCodeAttachment(toolName: String, args: [String: Any]) {
        guard let attachment = codeAttachment(toolName: toolName, args: args) else {
            codeEditor = nil
            removeAllChildren(of: codeHost)
            codeHost.visible = false
            return
        }
        if let editor = codeEditor {
            editor.setProfile(attachment.profile)
            editor.setText(attachment.source)
        } else {
            let editor = CodeEditor(engine: engine, profile: attachment.profile, initialText: attachment.source)
            editor.installInto(codeHost)
            codeEditor = editor
        }
        codeHost.visible = true
    }
}

@MainActor
private final class ChatCallCard {
    let widget: Box

    private let chats: ObjectChats
    private let titleLabel: Label
    private let card: PharoChatToolCallCard
    private var chatID: UUID

    init(call: ObjectChatToolCall, engine: Engine, onOpenChat: @escaping (UUID) -> Void) {
        chats = engine.objectChats
        chatID = call.chatID
        card = PharoChatToolCallCard(call: call, engine: engine, onSelect: { _ in })

        widget = Box(orientation: .vertical, spacing: 4)

        let header = Box(orientation: .horizontal, spacing: 6)
        titleLabel = Label(str: "")
        titleLabel.add(cssClass: "caption")
        titleLabel.add(cssClass: "dim-label")
        titleLabel.halign = .start
        titleLabel.xalign = 0
        titleLabel.hexpand = true
        titleLabel.ellipsize = .end
        header.append(child: titleLabel)

        let open = Button(label: "Open Chat")
        open.add(cssClass: "flat")
        open.add(cssClass: "caption")
        open.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                onOpenChat(self.chatID)
            }
        }
        header.append(child: open)
        widget.append(child: header)

        widget.append(child: card.widget)

        update(call)
    }

    func update(_ call: ObjectChatToolCall) {
        chatID = call.chatID
        titleLabel.label = chats.chats.first { $0.id == call.chatID }.map(chats.displayTitle(of:)) ?? ""
        card.update(call)
    }
}

@MainActor
private final class RequestUserInputCard {
    let widget: Box

    private let questionLabel: Label
    private let timeLabel: Label
    private let optionsBox: Box
    private let answerEntry: Entry
    private let answerRow: Box
    private let submitButton: Button
    private let onSubmit: (String) -> Void

    init(action: MissionAction, onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit

        widget = Box(orientation: .vertical, spacing: 6)
        widget.add(cssClass: "card")
        widget.add(cssClass: "luma-mission-queue-input-card")

        let inner = Box(orientation: .vertical, spacing: 8)
        inner.marginStart = 12
        inner.marginEnd = 12
        inner.marginTop = 10
        inner.marginBottom = 10
        widget.append(child: inner)

        let header = Box(orientation: .horizontal, spacing: 8)
        let icon = Gtk.Image(iconName: "dialog-question-symbolic")
        icon.pixelSize = 14
        header.append(child: icon)
        let title = Label(str: "Agent is asking")
        title.halign = .start
        title.hexpand = true
        title.add(cssClass: "heading")
        title.add(cssClass: "caption")
        header.append(child: title)
        timeLabel = Label(str: "")
        timeLabel.add(cssClass: "dim-label")
        timeLabel.add(cssClass: "caption")
        header.append(child: timeLabel)
        inner.append(child: header)

        questionLabel = Label(str: "")
        questionLabel.halign = .fill
        questionLabel.xalign = 0
        questionLabel.wrap = true
        questionLabel.selectable = true
        inner.append(child: questionLabel)

        optionsBox = Box(orientation: .vertical, spacing: 6)
        inner.append(child: optionsBox)

        answerEntry = Entry()
        answerEntry.placeholderText = "Your answer"
        answerEntry.hexpand = true
        answerRow = Box(orientation: .horizontal, spacing: 6)
        answerRow.append(child: answerEntry)
        submitButton = Button(label: "Submit")
        submitButton.add(cssClass: "suggested-action")
        submitButton.sensitive = false
        answerRow.append(child: submitButton)
        inner.append(child: answerRow)

        answerEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trimmed = (self.answerEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.submitButton.sensitive = !trimmed.isEmpty
            }
        }
        submitButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = (self.answerEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.onSubmit(text)
            }
        }

        update(action: action)
    }

    func update(action: MissionAction) {
        timeLabel.label = RelativeTime.string(from: action.requestedAt)
        let parsed = parseArgs(action.argsJSON)
        questionLabel.label = (parsed["question"] as? String) ?? "(no question provided)"

        while let child = optionsBox.firstChild {
            optionsBox.remove(child: child)
        }
        let options = parsed["options"] as? [String]
        if let options, !options.isEmpty {
            answerRow.visible = false
            for option in options {
                let button = Button(label: option)
                button.halign = .fill
                button.add(cssClass: "flat")
                button.onClicked { [weak self, option] _ in
                    MainActor.assumeIsolated { self?.onSubmit(option) }
                }
                optionsBox.append(child: button)
            }
        } else {
            answerRow.visible = true
        }
    }

    private func parseArgs(_ json: String) -> [String: Any] {
        parsedArgs(json)
    }
}

@MainActor
final class MissionActionDecision {
    let widget: Box

    private weak var engine: Engine?
    private var action: MissionAction
    private let onApprove: () -> Void
    private let onReject: () -> Void

    init(action: MissionAction, engine: Engine?, onApprove: @escaping () -> Void, onReject: @escaping () -> Void) {
        self.action = action
        self.engine = engine
        self.onApprove = onApprove
        self.onReject = onReject
        widget = Box(orientation: .horizontal, spacing: 6)
        follow()
    }

    func update(action: MissionAction) {
        self.action = action
        render()
    }

    private func follow() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func render() {
        guard let engine else { return }
        while let child = widget.firstChild {
            widget.remove(child: child)
        }
        if engine.canApprove(action) {
            widget.append(child: rejectButton())
            let spacer = Label(str: "")
            spacer.hexpand = true
            widget.append(child: spacer)
            let approve = Button(label: "Approve")
            approve.add(cssClass: "suggested-action")
            approve.onClicked { [onApprove] _ in
                MainActor.assumeIsolated { onApprove() }
            }
            widget.append(child: approve)
        } else {
            let executorName = engine.executor(of: action)?.name ?? "the member who started the mission"
            let note = Label(str: ObjectChatCallHold.note(waitingFor: executorName, hold: engine.hold(on: action)))
            note.add(cssClass: "caption")
            note.add(cssClass: "dim-label")
            note.halign = .fill
            note.xalign = 0
            note.wrap = true
            note.hexpand = true
            widget.append(child: note)
            widget.append(child: rejectButton())
        }
    }

    private func rejectButton() -> Button {
        let reject = Button(label: "Reject")
        reject.add(cssClass: "destructive-action")
        reject.add(cssClass: "flat")
        reject.valign = .center
        reject.onClicked { [onReject] _ in
            MainActor.assumeIsolated { onReject() }
        }
        return reject
    }

    static func asksMe(_ action: MissionAction, engine: Engine) -> Bool {
        action.toolName == MissionTools.requestUserInputToolName || engine.canApprove(action)
    }
}

private struct CodeAttachment {
    let source: String
    let profile: EditorProfile
}

private func codeAttachment(toolName: String, args: [String: Any]) -> CodeAttachment? {
    switch toolName {
    case "eval_repl":
        return (args["code"] as? String).map { CodeAttachment(source: $0, profile: .fridaCodeShare()) }
    case "install_tracer_hook", "update_tracer_hook":
        return (args["code"] as? String).map { CodeAttachment(source: $0, profile: .fridaTracerHook(packages: [])) }
    case "write_custom_instrument_file", "create_custom_instrument_file", "update_custom_instrument_file":
        return (args["contents"] as? String).map { CodeAttachment(source: $0, profile: .fridaTracerHook(packages: [])) }
    default:
        return nil
    }
}

private func jsonWithoutCodeField(toolName: String, args: [String: Any]) -> String? {
    var stripped = args
    switch toolName {
    case "eval_repl", "install_tracer_hook", "update_tracer_hook":
        stripped.removeValue(forKey: "code")
    case "write_custom_instrument_file", "create_custom_instrument_file", "update_custom_instrument_file":
        stripped.removeValue(forKey: "contents")
    default:
        break
    }
    if stripped.isEmpty { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: stripped, options: [.prettyPrinted, .sortedKeys]),
        let str = String(data: data, encoding: .utf8)
    else { return nil }
    return str
}

private func parsedArgs(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

private func removeAllChildren(of box: Box) {
    while let child = box.firstChild {
        box.remove(child: child)
    }
}

