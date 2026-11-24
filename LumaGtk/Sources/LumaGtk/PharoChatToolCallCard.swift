import Adw
import Foundation
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class PharoChatToolCallCard {
    let widget: Box

    private var call: ObjectChatToolCall
    private let engine: Engine
    private let onSelect: (PharoObject) -> Void
    private let inner: Box
    private var shown: Shown?
    private var showsSnapshot = false
    private var failure: String?
    private var snapshotView: PharoSnapshotView?

    private struct Shown: Equatable {
        let updatedAt: Date
        let isWaitingForMe: Bool
        let hold: ObjectChatCallHold?
        let isLive: Bool
    }

    init(call: ObjectChatToolCall, engine: Engine, onSelect: @escaping (PharoObject) -> Void) {
        self.call = call
        self.engine = engine
        self.onSelect = onSelect

        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "card")
        widget.hexpand = true

        inner = Box(orientation: .vertical, spacing: 6)
        inner.marginStart = 8
        inner.marginEnd = 8
        inner.marginTop = 8
        inner.marginBottom = 8
        widget.append(child: inner)

        update(call)
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    func update(_ call: ObjectChatToolCall) {
        self.call = call
        let now = Shown(updatedAt: call.updatedAt, isWaitingForMe: isWaitingForMe, hold: chats.hold(on: call), isLive: isLive)
        guard now != shown else { return }
        shown = now
        render()
    }

    private var isWaitingForMe: Bool {
        call.status == .proposed && chats.isExecutor(of: call)
    }

    private var isLive: Bool {
        call.objectID.map { chats.isLive($0, in: call.chatID) } ?? false
    }

    private func render() {
        while let child = inner.firstChild {
            inner.remove(child: child)
        }
        snapshotView = nil
        inner.append(child: header())
        details()
        outcome()
        if let failure {
            inner.append(child: caption(failure, classes: ["error"], selectable: true))
        }
    }

    private func header() -> Box {
        let header = Box(orientation: .horizontal, spacing: 6)
        let icon = Gtk.Image(iconName: symbol)
        icon.pixelSize = 14
        icon.add(cssClass: "accent")
        header.append(child: icon)
        let title = Label(str: self.title)
        title.add(cssClass: "heading")
        title.halign = .start
        title.xalign = 0
        title.hexpand = true
        header.append(child: title)
        return header
    }

    private var symbol: String {
        switch call.tool {
        case ObjectChats.evaluateTool: "utilities-terminal-symbolic"
        case ObjectChats.viewTool: "view-reveal-symbolic"
        case ObjectChats.objectsTool: "view-list-bullet-symbolic"
        default: "applications-engineering-symbolic"
        }
    }

    private var title: String {
        switch call.tool {
        case ObjectChats.evaluateTool: "Evaluate"
        case ObjectChats.viewTool: "Read a view"
        case ObjectChats.objectsTool: "List the objects"
        default: call.tool
        }
    }

    private func details() {
        switch call.tool {
        case ObjectChats.evaluateTool:
            inner.append(child: PharoStyledSource(source: code, errorPosition: call.status == .failed ? call.errorPosition : nil).widget)
            for binding in bindings {
                inner.append(child: mentioning(binding.objectID, after: "\(binding.name) →"))
            }
        case ObjectChats.viewTool:
            inner.append(child: mentioning(argument("object_id"), after: "\(argument("view")) of"))
        case ObjectChats.objectsTool:
            break
        default:
            inner.append(child: caption(argumentsJSON, classes: ["monospace", "luma-mission-code"], selectable: true))
        }
    }

    private func mentioning(_ objectID: String, after text: String) -> Box {
        let classes = ["caption", "monospace", "dim-label"]
        let line = Box(orientation: .horizontal, spacing: 4)
        line.append(child: caption(text, classes: ["monospace", "dim-label"], selectable: false))
        line.append(child: PharoChatObjectID.make(objectID, collaboration: engine.collaboration, classes: classes))
        return line
    }

    private func caption(_ text: String, classes: [String], selectable: Bool) -> Label {
        let label = Label(str: text)
        label.add(cssClass: "caption")
        for cssClass in classes {
            label.add(cssClass: cssClass)
        }
        label.halign = .fill
        label.xalign = 0
        label.wrap = true
        label.selectable = selectable
        return label
    }

    private func outcome() {
        switch call.status {
        case .proposed:
            if isWaitingForMe {
                inner.append(child: decision())
            } else if let hold = chats.hold(on: call) {
                inner.append(child: stranded(hold))
            } else {
                let note = ObjectChatCallHold.note(waitingFor: executorName, hold: nil)
                inner.append(child: caption(note, classes: ["dim-label"], selectable: false))
            }
        case .running:
            let row = Box(orientation: .horizontal, spacing: 6)
            row.append(child: makeSpinner())
            row.append(child: caption("Running…", classes: ["dim-label"], selectable: false))
            inner.append(child: row)
        case .succeeded:
            if call.tool == ObjectChats.evaluateTool, let objectID = call.objectID {
                result(objectID)
            } else {
                inner.append(child: caption(call.summary ?? "", classes: ["dim-label"], selectable: true))
            }
        case .failed:
            inner.append(child: caption(call.error ?? call.summary ?? "It failed.", classes: ["error"], selectable: true))
        case .rejected:
            inner.append(child: caption(call.error.map { "Rejected: \($0)" } ?? "Rejected", classes: ["dim-label"], selectable: false))
        }
    }

    private func decision() -> Box {
        let row = Box(orientation: .horizontal, spacing: 6)
        let reject = Button(label: "Reject")
        reject.add(cssClass: "destructive-action")
        reject.add(cssClass: "flat")
        reject.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.confirmRejection() }
        }
        row.append(child: reject)
        guard chats.canRun(call) else {
            let wait = ObjectChatCallHold.note(waitingFor: executorName, hold: chats.hold(on: call))
            let note = caption(wait, classes: ["dim-label"], selectable: false)
            note.hexpand = true
            row.prepend(child: note)
            return row
        }
        let spacer = Label(str: "")
        spacer.hexpand = true
        row.append(child: spacer)
        row.append(child: runButton())
        return row
    }

    private func runButton() -> Widget {
        guard call.tool == ObjectChats.evaluateTool else {
            let run = Button(label: "Run")
            run.add(cssClass: "suggested-action")
            run.onClicked { [weak self] _ in
                MainActor.assumeIsolated { self?.run() }
            }
            return run
        }
        let always = Button(label: "Run, and Run My Expressions Without Asking")
        always.add(cssClass: "flat")
        let menu = Popover()
        menu.set(child: always)
        let run = Adw.SplitButton()
        run.set(label: "Run")
        run.add(cssClass: "suggested-action")
        run.set(popover: menu)
        run.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        always.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                menu.popdown()
                ObjectChatRunSetting.shared.runsWithoutAsking = true
                self?.run()
            }
        }
        return run
    }

    private func run() {
        let chats = chats
        let callID = call.id
        Task { @MainActor in await chats.run(callID) }
    }

    private func confirmRejection() {
        let chats = chats
        let callID = call.id
        RejectionDialog.present(
            heading: "Reject this call?",
            body: "Tell the assistant why you rejected it. This signal can help it adjust.",
            parent: widget
        ) { reason in
            chats.reject(callID, reason: reason)
        }
    }

    private func stranded(_ hold: ObjectChatCallHold) -> Box {
        let why = hold.reason(executorName: executorName)
        let row = Box(orientation: .horizontal, spacing: 6)
        let note = caption(ObjectChatCallHold.note(waitingFor: executorName, hold: hold), classes: ["dim-label"], selectable: false)
        note.hexpand = true
        row.append(child: note)
        if chats.isAsker(of: call) {
            let cancel = Button(label: "Cancel")
            cancel.valign = .center
            cancel.onClicked { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.chats.reject(self.call.id, reason: "Canceled while waiting: \(why)")
                }
            }
            row.append(child: cancel)
        }
        return row
    }

    private var executorName: String {
        call.executor?.name ?? "the session's host"
    }

    private func result(_ objectID: String) {
        let live = isLive
        let icon = Gtk.Image(iconName: live ? "go-next-symbolic" : (showsSnapshot ? "pan-down-symbolic" : "pan-end-symbolic"))
        icon.add(cssClass: "accent")
        icon.valign = .start
        let summary = Label(str: printString(of: objectID))
        summary.add(cssClass: "monospace")
        summary.add(cssClass: "accent")
        summary.xalign = 0
        summary.wrap = true
        summary.hexpand = true

        let content = Box(orientation: .horizontal, spacing: 4)
        content.append(child: icon)
        content.append(child: PharoChatObjectID.make(objectID, collaboration: engine.collaboration, classes: ["monospace", "accent"]))
        content.append(child: summary)

        let link = Button()
        link.set(child: content)
        link.add(cssClass: "flat")
        link.halign = .fill
        link.tooltipText = live ? "Open in the next pane" : "Show what it was when it was made"
        link.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if live {
                    self.open(objectID)
                } else {
                    self.showsSnapshot.toggle()
                    self.render()
                }
            }
        }
        inner.append(child: link)

        guard !live, showsSnapshot else { return }
        if let snapshot = chats.thread(of: call.chatID).objects.first(where: { $0.objectID == objectID })?.snapshot {
            let view = PharoSnapshotView(snapshot: snapshot)
            view.widget.setSizeRequest(width: -1, height: 220)
            snapshotView = view
            let frame = Frame()
            frame.set(child: view.widget)
            inner.append(child: frame)
        }
        let runAgain = Button(label: "Run Again")
        runAgain.halign = .start
        runAgain.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.runAgain() }
        }
        inner.append(child: runAgain)
    }

    private func printString(of objectID: String) -> String {
        let summary = call.summary ?? ""
        let prefix = "\(objectID): "
        return summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary
    }

    private func open(_ objectID: String) {
        Task { @MainActor in
            do {
                let object = try await chats.open(objectID, in: call.chatID)
                failure = nil
                render()
                onSelect(object)
            } catch {
                failure = error.localizedDescription
                render()
            }
        }
    }

    private func runAgain() {
        Task { @MainActor in
            do {
                try await chats.runAgain(call.id)
                failure = nil
                showsSnapshot = false
            } catch {
                failure = error.localizedDescription
            }
            render()
        }
    }

    private var code: String {
        argument("code")
    }

    private var bindings: [(name: String, objectID: String)] {
        guard case .array(let listed) = call.args["bindings"] else { return [] }
        return listed.compactMap {
            guard case .object(let binding) = $0, case .string(let name) = binding["name"],
                case .string(let objectID) = binding["object_id"]
            else { return nil }
            return (name, objectID)
        }
    }

    private func argument(_ name: String) -> String {
        if case .string(let value) = call.args[name] { return value }
        return ""
    }

    private var argumentsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try! encoder.encode(call.args), as: UTF8.self)
    }
}

extension ObjectChatCallHold {
    static func note(waitingFor executorName: String, hold: ObjectChatCallHold?) -> String {
        hold.map { "Waiting: \($0.reason(executorName: executorName))" } ?? "Waiting for \(executorName)"
    }

    func reason(executorName: String) -> String {
        switch self {
        case .executorOffline:
            "\(executorName) is offline."
        case .executorNoLongerHosts(let currentHost):
            "\(executorName) no longer hosts this session" + (currentHost.map { "; \($0.name) does now." } ?? ".")
        case .sessionDetached:
            "the session is not attached."
        }
    }
}
