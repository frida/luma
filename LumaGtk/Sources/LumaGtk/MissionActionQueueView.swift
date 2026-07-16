import Adw
import Foundation
import Gtk
import LumaCore

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

    func update(actions: [MissionAction]) {
        countLabel.label = "\(actions.count) pending"

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
        if actions.isEmpty {
            bodyContainer.append(child: placeholder)
        } else {
            bodyContainer.append(child: listScroll)
        }
    }

    private func presentRejectDialog(actionID: UUID, toolName: String) {
        let dialog = Adw.AlertDialog(
            heading: "Reject action?",
            body:
                "Tell the agent why you rejected \(toolName). This signal can help it adjust."
        )

        let body = Box(orientation: .vertical, spacing: 8)
        body.marginStart = 12
        body.marginEnd = 12
        body.marginTop = 8
        body.marginBottom = 8
        let entry = Entry()
        entry.placeholderText = "Reason (optional)"
        entry.hexpand = true
        body.append(child: entry)
        dialog.extraChild = WidgetRef(body)

        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "reject", label: "Reject")
        dialog.setResponseAppearance(response: "reject", appearance: .destructive)
        dialog.setDefault(response: "cancel")
        dialog.setClose(response: "cancel")

        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard responseID == "reject" else { return }
                let reason = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let payload = reason.isEmpty ? nil : reason
                Task { @MainActor in
                    await self.engine?.rejectMissionAction(
                        actionID: actionID,
                        reason: payload
                    )
                }
            }
        }
        dialog.present(parent: parentWindow)
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
    private var codeEditor: MonacoEditor?
    private let rationaleLabel: Label
    private let approveButton: Button
    private let rejectButton: Button
    private let onApprove: (UUID) -> Void
    private let onReject: (UUID, String) -> Void

    init(
        action: MissionAction,
        onApprove: @escaping (UUID) -> Void,
        onReject: @escaping (UUID, String) -> Void
    ) {
        self.onApprove = onApprove
        self.onReject = onReject

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

        let actionsRow = Box(orientation: .horizontal, spacing: 6)
        rejectButton = Button(label: "Reject")
        rejectButton.add(cssClass: "destructive-action")
        rejectButton.add(cssClass: "flat")
        actionsRow.append(child: rejectButton)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actionsRow.append(child: spacer)
        approveButton = Button(label: "Approve")
        approveButton.add(cssClass: "suggested-action")
        actionsRow.append(child: approveButton)
        inner.append(child: actionsRow)

        approveButton.onClicked { [action] _ in
            MainActor.assumeIsolated { onApprove(action.id) }
        }
        rejectButton.onClicked { [action] _ in
            MainActor.assumeIsolated { onReject(action.id, action.toolName) }
        }

        update(action: action)
    }

    func update(action: MissionAction) {
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
            let editor = MonacoEditor(profile: attachment.profile, initialText: attachment.source)
            editor.installInto(codeHost)
            codeEditor = editor
        }
        codeHost.visible = true
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

