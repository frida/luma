import Adw
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class SessionDetailView {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID

    private let titleLabel: Label
    private var summaryValues: [SummaryField: Label] = [:]
    private var baseAddress: UInt64?

    private enum SummaryField: CaseIterable {
        case status
        case device
        case pid
        case platform
        case architecture
        case pointerSize
        case mainModule
        case path
        case base
        case size

        var title: String {
            switch self {
            case .status: return "Status"
            case .device: return "Device"
            case .pid: return "PID"
            case .platform: return "Platform"
            case .architecture: return "Architecture"
            case .pointerSize: return "Pointer size"
            case .mainModule: return "Main module"
            case .path: return "Path"
            case .base: return "Base"
            case .size: return "Size"
            }
        }
    }

    init(engine: Engine, session: LumaCore.ProcessSession) {
        self.engine = engine
        self.sessionID = session.id

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        let body = Box(orientation: .vertical, spacing: 12)
        body.marginStart = 16
        body.marginEnd = 16
        body.marginBottom = 16
        body.hexpand = true
        body.vexpand = true

        titleLabel = Label(str: session.processName)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-2")

        let summaryBox = Box(orientation: .vertical, spacing: 4)
        summaryBox.halign = .start

        let summaryScroll = ScrolledWindow()
        summaryScroll.hexpand = true
        summaryScroll.vexpand = true
        summaryScroll.set(child: summaryBox)

        body.append(child: titleLabel)
        body.append(child: summaryScroll)

        widget.append(child: body)

        let keyGroup = SizeGroup(mode: .horizontal)
        for field in SummaryField.allCases {
            summaryBox.append(child: makeSummaryRow(field, keyGroup: keyGroup))
        }

        applySessionState(session)
    }

    func applySessionState() {
        guard let session = engine?.session(id: sessionID) else { return }
        applySessionState(session)
    }

    private func applySessionState(_ session: LumaCore.ProcessSession) {
        titleLabel.label = session.processName
        updateSummary(session: session)
    }

    private func updateSummary(session: LumaCore.ProcessSession) {
        let node = engine?.node(forSessionID: sessionID)
        let platform = node?.processInfo.map { ($0.platform, $0.arch, $0.pointerSize) }
            ?? session.processInfo.map { ($0.platform, $0.arch, $0.pointerSize) }
        let main = node?.mainModule
        baseAddress = main?.base

        show(.status, statusText(session: session, node: node))
        show(.device, node?.deviceName ?? session.deviceName)
        show(.pid, String(node?.pid ?? session.lastKnownPID))
        show(.platform, platform?.0)
        show(.architecture, platform?.1)
        show(.pointerSize, platform.map { "\($0.2) bytes" })
        show(.mainModule, main?.name)
        show(.path, main?.path)
        show(.base, main.map { String(format: "0x%llx", $0.base) })
        show(.size, main.map { "\($0.size) bytes" })
    }

    private func statusText(session: LumaCore.ProcessSession, node: LumaCore.ProcessNode?) -> String {
        if let node {
            switch node.phase {
            case .attaching: return "Attaching\u{2026}"
            case .attached: return "Attached"
            case .detached: return "Detached"
            }
        }
        switch session.phase {
        case .attaching: return "Attaching\u{2026}"
        case .awaitingInitialResume: return "Awaiting initial resume"
        case .attached: return "Attached"
        case .idle: return "Idle"
        }
    }

    private func show(_ field: SummaryField, _ value: String?) {
        let label = summaryValues[field]!
        label.parent!.visible = value != nil
        if let value, label.label != value {
            label.label = value
        }
    }

    private func makeSummaryRow(_ field: SummaryField, keyGroup: SizeGroup) -> Box {
        let row = Box(orientation: .horizontal, spacing: 12)
        row.visible = false

        let key = Label(str: field.title)
        key.halign = .start
        key.xalign = 0
        key.add(cssClass: "dim-label")
        keyGroup.add(widget: key)

        let value = Label(str: "")
        value.halign = .start
        value.xalign = 0
        value.hexpand = true
        if field == .base {
            attachBaseAddressMenu(to: value)
        } else {
            value.selectable = true
            value.wrap = true
        }

        row.append(child: key)
        row.append(child: value)
        summaryValues[field] = value
        return row
    }

    private func attachBaseAddressMenu(to label: Label) {
        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = .capture
        gesture.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                let address = self.baseAddress!
                _ = gesture.set(state: .claimed)
                AddressActionMenu.present(
                    at: gesture.widget!,
                    x: x,
                    y: y,
                    engine: engine,
                    sessionID: self.sessionID,
                    address: address,
                    value: String(format: "0x%llx", address)
                )
            }
        }
        label.add(controller: gesture)
    }
}
