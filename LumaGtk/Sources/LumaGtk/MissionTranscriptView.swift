import Adw
import Foundation
import Gtk
import LumaCore
import Pango

@MainActor
final class MissionTranscriptView {
    let widget: Box

    private let listBox: Box
    private let scroll: ScrolledWindow
    private let scroller: BottomScroller
    private let placeholder: Adw.StatusPage

    private var turnIDOrder: [UUID] = []
    private var cardsByTurnID: [UUID: TurnCard] = [:]
    private var liveCard: LiveCard?
    private var liveText: String = ""
    private var actionsByToolUseID: [String: MissionAction] = [:]
    private var actionsByTurnID: [UUID: [MissionAction]] = [:]

    init() {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        listBox = Box(orientation: .vertical, spacing: 12)
        listBox.marginStart = 18
        listBox.marginEnd = 18
        listBox.marginTop = 18
        listBox.marginBottom = 18
        listBox.hexpand = true

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: listBox)
        scroller = BottomScroller(scroll)

        placeholder = Adw.StatusPage()
        placeholder.set(iconName: "mail-send-symbolic")
        placeholder.set(title: "Mission ready")
        placeholder.set(description: "The agent will start replying as soon as it has a goal.")
        placeholder.hexpand = true
        placeholder.vexpand = true

        widget.append(child: placeholder)
    }

    func applyTurns(_ turns: [MissionTurn], actions: [MissionAction]) {
        rebuildActionMaps(actions)

        let liveAttached = liveCard?.widget.parent != nil
        if liveAttached, let live = liveCard {
            listBox.remove(child: live.widget)
        }

        let newOrder = turns.map(\.id)
        let removed = Set(turnIDOrder).subtracting(newOrder)
        for id in removed {
            if let card = cardsByTurnID.removeValue(forKey: id), card.widget.parent != nil {
                listBox.remove(child: card.widget)
            }
        }

        if turnIDOrder != newOrder {
            for id in turnIDOrder {
                if let card = cardsByTurnID[id], card.widget.parent != nil {
                    listBox.remove(child: card.widget)
                }
            }
            for turn in turns {
                let turnActions = actionsByTurnID[turn.id] ?? []
                if let card = cardsByTurnID[turn.id] {
                    card.update(turn: turn, actions: turnActions)
                    listBox.append(child: card.widget)
                } else {
                    let card = TurnCard(turn: turn, actions: turnActions)
                    cardsByTurnID[turn.id] = card
                    listBox.append(child: card.widget)
                }
            }
        } else {
            for turn in turns {
                let turnActions = actionsByTurnID[turn.id] ?? []
                cardsByTurnID[turn.id]?.update(turn: turn, actions: turnActions)
            }
        }

        if liveAttached, let live = liveCard {
            listBox.append(child: live.widget)
        }

        turnIDOrder = newOrder
        renderPlaceholderIfNeeded()
        scroller.pin()
    }

    func applyActions(_ actions: [MissionAction]) {
        rebuildActionMaps(actions)
        for (turnID, card) in cardsByTurnID {
            card.updateActions(
                actionsByTurnID[turnID] ?? [],
                map: actionsByToolUseID
            )
        }
    }

    func setLiveText(_ text: String) {
        liveText = text
        if text.isEmpty {
            if let live = liveCard {
                if live.widget.parent != nil {
                    listBox.remove(child: live.widget)
                }
                liveCard = nil
            }
            renderPlaceholderIfNeeded()
            return
        }
        if let live = liveCard {
            live.update(text: text)
        } else {
            let live = LiveCard(text: text)
            liveCard = live
            ensureScrollVisible()
            listBox.append(child: live.widget)
        }
        scroller.pin()
    }

    private func rebuildActionMaps(_ actions: [MissionAction]) {
        var byTool: [String: MissionAction] = [:]
        var byTurn: [UUID: [MissionAction]] = [:]
        for action in actions {
            if let id = action.toolCallID { byTool[id] = action }
            if let turnID = action.turnID {
                byTurn[turnID, default: []].append(action)
            }
        }
        actionsByToolUseID = byTool
        actionsByTurnID = byTurn
    }

    private func renderPlaceholderIfNeeded() {
        let isEmpty = cardsByTurnID.isEmpty && liveCard == nil
        if isEmpty {
            if scroll.parent != nil {
                widget.remove(child: scroll)
            }
            if placeholder.parent == nil {
                widget.append(child: placeholder)
            }
        } else {
            ensureScrollVisible()
        }
    }

    private func ensureScrollVisible() {
        if placeholder.parent != nil {
            widget.remove(child: placeholder)
        }
        if scroll.parent == nil {
            widget.append(child: scroll)
        }
    }

}

@MainActor
private final class TurnCard {
    let widget: Box
    private let bodyBox: Box
    private let titleLabel: Label
    private let titleIcon: Gtk.Image
    private let tokenLabel: Label

    private var lastBlocksJSON: String = ""
    private var blockEntries: [TurnBlockEntry] = []
    private var currentRoleClass: String = ""

    init(turn: MissionTurn, actions: [MissionAction]) {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "card")
        widget.add(cssClass: "luma-mission-card")
        widget.marginStart = 0
        widget.marginEnd = 0

        let inner = Box(orientation: .vertical, spacing: 8)
        inner.marginStart = 14
        inner.marginEnd = 14
        inner.marginTop = 12
        inner.marginBottom = 12
        widget.append(child: inner)

        let titleRow = Box(orientation: .horizontal, spacing: 8)
        titleIcon = Gtk.Image(iconName: "user-info-symbolic")
        titleIcon.pixelSize = 14
        titleRow.append(child: titleIcon)
        titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "heading")
        titleLabel.add(cssClass: "caption")
        titleRow.append(child: titleLabel)

        let spacer = Label(str: "")
        spacer.hexpand = true
        titleRow.append(child: spacer)

        tokenLabel = Label(str: "")
        tokenLabel.add(cssClass: "dim-label")
        tokenLabel.add(cssClass: "caption")
        tokenLabel.add(cssClass: "numeric")
        tokenLabel.visible = false
        titleRow.append(child: tokenLabel)

        inner.append(child: titleRow)

        bodyBox = Box(orientation: .vertical, spacing: 6)
        inner.append(child: bodyBox)

        update(turn: turn, actions: actions)
    }

    func update(turn: MissionTurn, actions: [MissionAction]) {
        let blocks = decodeBlocks(turn.contentJSON)
        let isToolResults = !blocks.isEmpty && turn.role == .user && blocks.allSatisfy {
            if case .text = $0.content { return false }
            return true
        }
        let roleClass = cssClass(for: turn.role, isToolResults: isToolResults)
        if roleClass != currentRoleClass {
            if !currentRoleClass.isEmpty {
                widget.remove(cssClass: currentRoleClass)
            }
            widget.add(cssClass: roleClass)
            currentRoleClass = roleClass
        }
        titleLabel.label = roleTitle(role: turn.role, isToolResults: isToolResults)
        titleIcon.set(name: roleIcon(role: turn.role, isToolResults: isToolResults))

        if turn.outputTokens > 0 {
            tokenLabel.label = "\(turn.outputTokens) tok"
            tokenLabel.visible = true
        } else {
            tokenLabel.visible = false
        }

        let actionMap: [String: MissionAction] = Dictionary(
            uniqueKeysWithValues: actions.compactMap { action -> (String, MissionAction)? in
                guard let id = action.toolCallID else { return nil }
                return (id, action)
            }
        )

        if turn.contentJSON != lastBlocksJSON {
            lastBlocksJSON = turn.contentJSON
            for entry in blockEntries where entry.widget.parent != nil {
                bodyBox.remove(child: entry.widget)
            }
            blockEntries.removeAll()
            for block in blocks {
                let entry = renderBlockEntry(block, actions: actionMap)
                blockEntries.append(entry)
                bodyBox.append(child: entry.widget)
            }
        } else {
            updateActions(actions, map: actionMap)
        }
    }

    func updateActions(_ actions: [MissionAction], map actionMap: [String: MissionAction]) {
        for entry in blockEntries {
            if case .toolUse(let id, _, _) = entry.block.content,
                let toolBlock = entry.toolBlock
            {
                toolBlock.update(action: actionMap[id])
            }
        }
    }
}

@MainActor
private func roleTitle(role: MissionTurnRole, isToolResults: Bool) -> String {
    switch role {
    case .assistant: return "Assistant"
    case .user: return isToolResults ? "Tool results" : "You"
    case .tool: return "Tool"
    }
}

@MainActor
private func roleIcon(role: MissionTurnRole, isToolResults: Bool) -> String {
    switch role {
    case .assistant: return "applications-graphics-symbolic"
    case .user:
        return isToolResults ? "applications-engineering-symbolic" : "avatar-default-symbolic"
    case .tool: return "utilities-terminal-symbolic"
    }
}

@MainActor
private func cssClass(for role: MissionTurnRole, isToolResults: Bool) -> String {
    switch role {
    case .assistant: return "luma-mission-card-assistant"
    case .user: return isToolResults ? "luma-mission-card-tool" : "luma-mission-card-user"
    case .tool: return "luma-mission-card-tool"
    }
}

@MainActor
private func decodeBlocks(_ json: String) -> [LLMContentBlock] {
    guard let data = json.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([LLMContentBlock].self, from: data)) ?? []
}

@MainActor
fileprivate struct TurnBlockEntry {
    let block: LLMContentBlock
    let widget: Widget
    let toolBlock: MissionToolUseBlock?
}

@MainActor
private func renderBlockEntry(
    _ block: LLMContentBlock,
    actions: [String: MissionAction]
) -> TurnBlockEntry {
    switch block.content {
    case .text(let text):
        let widget = MarkdownWidget.make(markdown: text)
        return TurnBlockEntry(block: block, widget: widget, toolBlock: nil)
    case .thinking(let text, _):
        let widget = MissionDisclosure.make(
            title: "Thinking",
            iconName: "view-reveal-symbolic",
            child: MarkdownWidget.make(markdown: text, dimmed: true)
        )
        return TurnBlockEntry(block: block, widget: widget, toolBlock: nil)
    case .redactedThinking:
        let label = Label(str: "[redacted thinking]")
        label.halign = .start
        label.add(cssClass: "dim-label")
        label.add(cssClass: "caption")
        return TurnBlockEntry(block: block, widget: label, toolBlock: nil)
    case .toolUse(let id, let name, let inputJSON):
        let toolBlock = MissionToolUseBlock(
            id: id,
            name: name,
            inputJSON: inputJSON,
            action: actions[id]
        )
        return TurnBlockEntry(block: block, widget: toolBlock.widget, toolBlock: toolBlock)
    case .toolResult(_, let content, let isError, _):
        let widget = MissionToolResultBlock.make(content: content, isError: isError)
        return TurnBlockEntry(block: block, widget: widget, toolBlock: nil)
    }
}

@MainActor
private final class LiveCard {
    let widget: Box
    private let bodySlot: Box

    init(text: String) {
        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "card")
        widget.add(cssClass: "luma-mission-card-assistant")

        let inner = Box(orientation: .vertical, spacing: 8)
        inner.marginStart = 14
        inner.marginEnd = 14
        inner.marginTop = 12
        inner.marginBottom = 12
        widget.append(child: inner)

        let header = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: "applications-graphics-symbolic")
        icon.pixelSize = 14
        header.append(child: icon)
        let label = Label(str: "Streaming…")
        label.halign = .start
        label.add(cssClass: "heading")
        label.add(cssClass: "caption")
        header.append(child: label)
        let dots = Gtk.Spinner()
        dots.spinning = true
        dots.valign = .center
        header.append(child: dots)
        let spacer = Label(str: "")
        spacer.hexpand = true
        header.append(child: spacer)
        inner.append(child: header)

        bodySlot = Box(orientation: .vertical, spacing: 8)
        inner.append(child: bodySlot)
        fill(text: text)
    }

    func update(text: String) {
        fill(text: text)
    }

    private func fill(text: String) {
        while let child = bodySlot.firstChild {
            bodySlot.remove(child: child)
        }
        bodySlot.append(child: MarkdownWidget.make(markdown: MarkdownStreaming.stablePrefix(of: text)))
    }
}

@MainActor
enum MissionDisclosure {
    static func make(title: String, iconName: String?, child: Widget) -> Widget {
        let expander = Expander(label: "")
        let titleBox = Box(orientation: .horizontal, spacing: 6)
        if let iconName {
            let icon = Gtk.Image(iconName: iconName)
            icon.pixelSize = 14
            titleBox.append(child: icon)
        }
        let titleLabel = Label(str: title)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "heading")
        titleLabel.add(cssClass: "caption")
        titleBox.append(child: titleLabel)
        expander.set(labelWidget: titleBox)
        let bodyBox = Box(orientation: .vertical, spacing: 4)
        bodyBox.marginStart = 6
        bodyBox.marginTop = 4
        bodyBox.marginBottom = 4
        bodyBox.append(child: child)
        expander.set(child: bodyBox)
        return expander
    }
}

@MainActor
final class MissionToolUseBlock {
    let widget: Box
    private let pillSlot: Box
    private let summarySlot: Box
    private let icon: Gtk.Image

    init(id: String, name: String, inputJSON: String, action: MissionAction?) {
        widget = Box(orientation: .vertical, spacing: 6)
        widget.add(cssClass: "luma-mission-tool-use")
        pillSlot = Box(orientation: .horizontal, spacing: 0)
        summarySlot = Box(orientation: .vertical, spacing: 0)

        let header = Box(orientation: .horizontal, spacing: 8)
        icon = Gtk.Image(
            iconName: action?.isObserve == true
                ? "view-conceal-symbolic"
                : "applications-engineering-symbolic"
        )
        icon.pixelSize = 14
        header.append(child: icon)
        let nameLabel = Label(str: name)
        nameLabel.halign = .start
        nameLabel.add(cssClass: "heading")
        nameLabel.add(cssClass: "monospace")
        nameLabel.add(cssClass: "caption")
        header.append(child: nameLabel)
        header.append(child: pillSlot)
        let spacer = Label(str: "")
        spacer.hexpand = true
        header.append(child: spacer)
        widget.append(child: header)

        if !inputJSON.isEmpty, inputJSON != "{}" {
            let codeLabel = Label(str: prettyJSON(inputJSON))
            codeLabel.halign = .fill
            codeLabel.xalign = 0
            codeLabel.wrap = true
            codeLabel.selectable = true
            codeLabel.add(cssClass: "monospace")
            codeLabel.add(cssClass: "caption")
            codeLabel.add(cssClass: "luma-mission-code")
            widget.append(child: codeLabel)
        }

        widget.append(child: summarySlot)
        widget.tooltipText = id
        update(action: action)
    }

    func update(action: MissionAction?) {
        icon.set(
            name: action?.isObserve == true
                ? "view-conceal-symbolic"
                : "applications-engineering-symbolic"
        )

        while let child = pillSlot.firstChild {
            pillSlot.remove(child: child)
        }
        if let action {
            pillSlot.append(child: MissionPill.makeActionStatus(action.status))
        }

        while let child = summarySlot.firstChild {
            summarySlot.remove(child: child)
        }
        if let summary = action?.resultSummary, !summary.isEmpty {
            let label = Label(str: summary)
            label.halign = .start
            label.xalign = 0
            label.wrap = true
            label.selectable = true
            label.add(cssClass: "dim-label")
            label.add(cssClass: "caption")
            summarySlot.append(child: label)
        }
    }
}

@MainActor
enum MissionToolResultBlock {
    static func make(content: String, isError: Bool) -> Widget {
        let title = isError ? "Tool result (error)" : "Tool result"
        let body = Label(str: content)
        body.halign = .fill
        body.xalign = 0
        body.wrap = true
        body.wrapMode = WrapMode.wordChar
        body.selectable = true
        body.add(cssClass: "monospace")
        body.add(cssClass: "caption")
        body.add(cssClass: "luma-mission-code")
        if isError {
            body.add(cssClass: "error")
        }
        return MissionDisclosure.make(
            title: title,
            iconName: isError ? "dialog-error-symbolic" : "object-select-symbolic",
            child: body
        )
    }
}

private func prettyJSON(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ),
        let str = String(data: pretty, encoding: .utf8)
    else { return raw }
    return str
}

