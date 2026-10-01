import CGtk
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class MissionInputBar {
    let widget: Box

    private weak var engine: Engine?
    private let missionID: UUID
    private let textView: TextView
    private let sendButton: Button
    private let interruptButton: Button
    private let getStatus: () -> MissionStatus

    init(
        engine: Engine?,
        missionID: UUID,
        getStatus: @escaping () -> MissionStatus
    ) {
        self.engine = engine
        self.missionID = missionID
        self.getStatus = getStatus

        widget = Box(orientation: .horizontal, spacing: 8)
        widget.marginStart = 16
        widget.marginEnd = 16
        widget.marginTop = 10
        widget.marginBottom = 12
        widget.hexpand = true
        widget.add(cssClass: "luma-mission-input-bar")

        textView = TextView()
        textView.wrapMode = .word
        textView.topMargin = 6
        textView.bottomMargin = 6
        textView.leftMargin = 8
        textView.rightMargin = 8
        textView.acceptsTab = false

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setSizeRequest(width: -1, height: 64)
        scroll.add(cssClass: "card")
        scroll.set(child: textView)
        widget.append(child: scroll)

        sendButton = Button(label: "Send")
        sendButton.add(cssClass: "suggested-action")
        sendButton.sensitive = false
        sendButton.valign = .end

        interruptButton = Button()
        let interruptContent = Box(orientation: .horizontal, spacing: 4)
        let interruptIcon = Gtk.Image(iconName: "media-playback-stop-symbolic")
        interruptIcon.pixelSize = 14
        interruptContent.append(child: interruptIcon)
        let interruptLabel = Label(str: "Interrupt")
        interruptContent.append(child: interruptLabel)
        interruptButton.set(child: interruptContent)
        interruptButton.add(cssClass: "destructive-action")
        interruptButton.add(cssClass: "flat")
        interruptButton.tooltipText =
            "Send the message and interrupt the agent's current step"
        interruptButton.sensitive = false
        interruptButton.valign = .end

        let buttonColumn = Box(orientation: .vertical, spacing: 6)
        buttonColumn.valign = .end
        buttonColumn.append(child: interruptButton)
        buttonColumn.append(child: sendButton)
        widget.append(child: buttonColumn)

        sendButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.send(interrupt: false) }
        }
        interruptButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.send(interrupt: true) }
        }
        if let buffer = textView.buffer {
            buffer.onChanged { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSensitivity() }
            }
        }

        let keyController = EventControllerKey()
        keyController.onKeyPressed { [weak self] _, keyval, _, state in
            MainActor.assumeIsolated {
                guard let self else { return false }
                let isReturn = Int32(keyval) == Gdk.keyReturn || Int32(keyval) == Gdk.keyKPEnter
                guard isReturn else { return false }
                if state.contains(.controlMask) || state.contains(.metaMask) {
                    if state.contains(.shiftMask) {
                        self.send(interrupt: true)
                    } else {
                        self.send(interrupt: false)
                    }
                    return true
                }
                return false
            }
        }
        textView.add(controller: keyController)

        update(status: getStatus())
    }

    func update(status: MissionStatus) {
        let isRunning = status == .running
        interruptButton.visible = isRunning
        refreshSensitivity()
    }

    private func refreshSensitivity() {
        let trimmed = trimmedText
        let hasText = !trimmed.isEmpty
        sendButton.sensitive = hasText
        interruptButton.sensitive = hasText
    }

    private var trimmedText: String {
        guard let buffer = textView.buffer else { return "" }
        let startPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let endPtr = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer {
            startPtr.deallocate()
            endPtr.deallocate()
        }
        let start = TextIter(startPtr)
        let end = TextIter(endPtr)
        buffer.getStart(iter: start)
        buffer.getEnd(iter: end)
        let text = buffer.getText(start: start, end: end, includeHiddenChars: true) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(interrupt: Bool) {
        let text = trimmedText
        guard !text.isEmpty else { return }
        guard let engine else { return }
        if interrupt {
            engine.sendMissionUserMessageNow(missionID: missionID, text: text)
        } else {
            engine.appendMissionUserMessage(missionID: missionID, text: text)
        }
        if let buffer = textView.buffer {
            buffer.set(text: "", len: 0)
        }
        Task { @MainActor in _ = self.textView.grabFocus() }
    }
}
