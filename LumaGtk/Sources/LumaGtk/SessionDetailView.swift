import Adw
import CGtk
import Foundation
import Gtk
import LumaCore

@MainActor
final class SessionDetailView {
    let widget: Box

    var onReestablish: (() -> Void)?
    var onArmRequested: (() -> Void)?

    private weak var engine: Engine?
    private let sessionID: UUID

    private let bannerSlot: Box
    private var currentBanner: Widget?
    private let titleLabel: Label
    private let summaryBox: Box
    private var summaryKeyGroup: SizeGroup

    init(engine: Engine, session: LumaCore.ProcessSession) {
        self.engine = engine
        self.sessionID = session.id

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        bannerSlot = Box(orientation: .vertical, spacing: 0)

        let body = Box(orientation: .vertical, spacing: 12)
        body.marginStart = 16
        body.marginEnd = 16
        body.marginBottom = 16
        body.hexpand = true
        body.vexpand = true

        titleLabel = Label(str: session.processName)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-2")

        summaryBox = Box(orientation: .vertical, spacing: 4)
        summaryBox.halign = .start
        summaryKeyGroup = SizeGroup(mode: .horizontal)

        let summaryScroll = ScrolledWindow()
        summaryScroll.hexpand = true
        summaryScroll.vexpand = true
        summaryScroll.set(child: summaryBox)

        body.append(child: titleLabel)
        body.append(child: summaryScroll)

        widget.append(child: bannerSlot)
        widget.append(child: body)

        rebuildSummary(session: session)
        applyBanner(for: session)
    }

    func applySessionState() {
        guard let session = engine?.session(id: sessionID) else { return }
        titleLabel.label = session.processName
        rebuildSummary(session: session)
        applyBanner(for: session)
    }

    private func applyBanner(for session: LumaCore.ProcessSession) {
        if let existing = currentBanner {
            bannerSlot.remove(child: existing)
            currentBanner = nil
        }
        guard SessionDetachedBanner.shouldShow(for: session) else { return }
        let gatingActive = engine?.isGatingActive(forDeviceID: session.deviceID) ?? false
        let banner = SessionDetachedBanner.make(
            for: session,
            gatingActive: gatingActive,
            canReattach: engine?.canTakeHosting(session) ?? true,
            onReattach: { [weak self] in self?.onReestablish?() },
            onDisarm: { [weak self] in self?.disarmSession(session.id) },
            onArm: { [weak self] in self?.onArmRequested?() },
            onResumeGating: { [weak self] in self?.resumeGating(for: session.id) }
        )
        bannerSlot.append(child: banner)
        currentBanner = banner
    }

    private func disarmSession(_ id: UUID) {
        guard let engine else { return }
        Task { @MainActor in await engine.disarmSession(id: id) }
    }

    private func resumeGating(for id: UUID) {
        guard let engine else { return }
        Task { @MainActor in await engine.resumeGating(forSessionID: id) }
    }

    private func rebuildSummary(session: LumaCore.ProcessSession) {
        clearBox(summaryBox)
        summaryKeyGroup = SizeGroup(mode: .horizontal)

        let node = engine?.node(forSessionID: sessionID)

        appendSummary(label: "Status", value: statusText(session: session, node: node))
        appendSummary(label: "Device", value: node?.deviceName ?? session.deviceName)
        appendSummary(label: "PID", value: String(node?.pid ?? session.lastKnownPID))

        if let info = node?.processInfo {
            appendSummary(label: "Platform", value: info.platform)
            appendSummary(label: "Architecture", value: info.arch)
            appendSummary(label: "Pointer size", value: "\(info.pointerSize) bytes")
        } else if let info = session.processInfo {
            appendSummary(label: "Platform", value: info.platform)
            appendSummary(label: "Architecture", value: info.arch)
            appendSummary(label: "Pointer size", value: "\(info.pointerSize) bytes")
        }

        if let main = node?.mainModule {
            appendSummary(label: "Main module", value: main.name)
            appendSummary(label: "Path", value: main.path)
            appendBaseSummary(address: main.base)
            appendSummary(label: "Size", value: "\(main.size) bytes")
        }
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

    private func appendSummary(label: String, value: String) {
        let row = Box(orientation: .horizontal, spacing: 12)

        let key = Label(str: label)
        key.halign = .start
        key.xalign = 0
        key.add(cssClass: "dim-label")
        summaryKeyGroup.add(widget: key)

        let val = Label(str: value)
        val.halign = .start
        val.selectable = true
        val.wrap = true
        val.xalign = 0
        val.hexpand = true

        row.append(child: key)
        row.append(child: val)
        summaryBox.append(child: row)
    }

    private func appendBaseSummary(address: UInt64) {
        let row = Box(orientation: .horizontal, spacing: 12)

        let key = Label(str: "Base")
        key.halign = .start
        key.xalign = 0
        key.add(cssClass: "dim-label")
        summaryKeyGroup.add(widget: key)

        let val = Label(str: String(format: "0x%llx", address))
        val.halign = .start
        val.selectable = false
        val.xalign = 0
        val.hexpand = true
        if let engine {
            AddressActionMenu.attach(to: val, engine: engine, sessionID: sessionID, address: address, value: String(format: "0x%llx", address))
        }

        row.append(child: key)
        row.append(child: val)
        summaryBox.append(child: row)
    }

    private func clearBox(_ box: Box) {
        while let child = box.firstChild {
            box.remove(child: child)
        }
    }
}
