import Adw
import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class VirtualMachinePanel {
    let widget: Box

    private weak var engine: Engine?
    private let onClose: () -> Void

    private let listBox: Box
    private let scroll: ScrolledWindow
    private let emptyState: Adw.StatusPage
    private let failureLabel: Label

    private var rows: [UUID: MachineRow] = [:]
    private var collapsed: Set<UUID> = []
    private var statePollTask: Task<Void, Never>?

    init(engine: Engine, onClose: @escaping () -> Void) {
        self.engine = engine
        self.onClose = onClose

        widget = Box(orientation: .vertical, spacing: 0)
        widget.setSizeRequest(width: 320, height: -1)

        let header = Box(orientation: .horizontal, spacing: 8)
        header.marginTop = 12
        header.marginStart = 12
        header.marginEnd = 12
        header.marginBottom = 8

        let title = Label(str: "Machines")
        title.add(cssClass: "heading")
        title.hexpand = true
        title.xalign = 0
        header.append(child: title)

        let close = Button()
        close.iconName = "window-close-symbolic"
        close.add(cssClass: "flat")
        close.tooltipText = "Close"
        close.onClicked { _ in
            MainActor.assumeIsolated { onClose() }
        }
        header.append(child: close)
        widget.append(child: header)

        listBox = Box(orientation: .vertical, spacing: 12)
        listBox.marginStart = 12
        listBox.marginEnd = 12
        listBox.marginBottom = 12

        scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.child = WidgetRef(listBox)
        widget.append(child: scroll)

        emptyState = Adw.StatusPage()
        emptyState.iconName = "computer-symbolic"
        emptyState.title = "No Machines"
        emptyState.description = "Boot one from the target picker to see it here."
        emptyState.vexpand = true
        widget.append(child: emptyState)

        failureLabel = Label(str: "")
        failureLabel.add(cssClass: "error")
        failureLabel.wrap = true
        failureLabel.xalign = 0
        failureLabel.marginStart = 12
        failureLabel.marginEnd = 12
        failureLabel.marginBottom = 8
        failureLabel.visible = false
        widget.append(child: failureLabel)

        rebuild()
        observe()
    }

    private func observe() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.virtualMachines.records
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rebuild()
                self.observe()
            }
        }
    }

    private func startStatePolling() {
        statePollTask?.cancel()
        statePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                for row in self.rows.values {
                    row.refreshState()
                }
            }
        }
    }

    private func rebuild() {
        guard let engine else { return }
        let records = engine.virtualMachines.records

        while let child = listBox.firstChild {
            listBox.remove(child: child)
        }
        rows.removeAll()

        emptyState.visible = records.isEmpty
        scroll.visible = !records.isEmpty
        guard !records.isEmpty else { return }

        for record in records {
            let row = MachineRow(
                engine: engine,
                record: record,
                isCollapsed: collapsed.contains(record.id),
                onToggleCollapsed: { [weak self] collapsedNow in
                    guard let self else { return }
                    if collapsedNow {
                        self.collapsed.insert(record.id)
                    } else {
                        self.collapsed.remove(record.id)
                    }
                },
                onFailure: { [weak self] message in
                    self?.showFailure(message)
                }
            )
            rows[record.id] = row
            listBox.append(child: row.widget)
        }

        startStatePolling()
    }

    private func showFailure(_ message: String?) {
        failureLabel.label = message ?? ""
        failureLabel.visible = (message != nil)
    }
}

@MainActor
private final class MachineRow {
    let widget: Box

    private weak var engine: Engine?
    private let record: VirtualMachineRecord
    private let onToggleCollapsed: (Bool) -> Void
    private let onFailure: (String?) -> Void

    private let stateLabel: Label
    private let primaryButton: Button
    private let disclosure: Button
    private let screenHost: Box
    private let menuButton: Button

    private var isCollapsed: Bool
    private var screen: VirtualMachineScreen?
    private var shownMachineID: ObjectIdentifier?
    private var lastSummary: String?

    init(
        engine: Engine,
        record: VirtualMachineRecord,
        isCollapsed: Bool,
        onToggleCollapsed: @escaping (Bool) -> Void,
        onFailure: @escaping (String?) -> Void
    ) {
        self.engine = engine
        self.record = record
        self.isCollapsed = isCollapsed
        self.onToggleCollapsed = onToggleCollapsed
        self.onFailure = onFailure

        widget = Box(orientation: .vertical, spacing: 8)

        let summary = Box(orientation: .horizontal, spacing: 10)

        disclosure = Button()
        disclosure.iconName = isCollapsed ? "pan-end-symbolic" : "pan-down-symbolic"
        disclosure.add(cssClass: "flat")
        summary.append(child: disclosure)

        let names = Box(orientation: .vertical, spacing: 2)
        names.hexpand = true
        let name = Label(str: record.name)
        name.xalign = 0
        name.add(cssClass: "heading")
        name.ellipsize = .end
        names.append(child: name)

        if let template = engine.virtualMachines.template(for: record), template.name != record.name {
            let subtitle = Label(str: template.name)
            subtitle.xalign = 0
            subtitle.add(cssClass: "dim-label")
            subtitle.add(cssClass: "caption")
            subtitle.ellipsize = .end
            names.append(child: subtitle)
        }
        summary.append(child: names)

        stateLabel = Label(str: "")
        stateLabel.add(cssClass: "dim-label")
        stateLabel.add(cssClass: "caption")
        stateLabel.ellipsize = .end
        summary.append(child: stateLabel)

        primaryButton = Button()
        primaryButton.add(cssClass: "flat")
        summary.append(child: primaryButton)

        menuButton = Button()
        menuButton.set(iconName: "view-more-symbolic")
        menuButton.add(cssClass: "flat")
        menuButton.tooltipText = "More\u{2026}"
        summary.append(child: menuButton)

        widget.append(child: summary)

        screenHost = Box(orientation: .vertical, spacing: 0)
        screenHost.setSizeRequest(width: -1, height: 200)
        widget.append(child: screenHost)

        disclosure.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleCollapsed() }
        }
        primaryButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.performPrimaryAction() }
        }
        menuButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.presentMenu() }
        }

        refreshState()
    }

    private var machine: (any VirtualMachine)? {
        engine?.virtualMachines.machine(for: record)
    }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        disclosure.iconName = isCollapsed ? "pan-end-symbolic" : "pan-down-symbolic"
        onToggleCollapsed(isCollapsed)
        refreshScreen()
    }

    func refreshState() {
        let machine = self.machine
        let summary: String?
        switch machine?.state {
        case .running, .stopped, nil: summary = nil
        case .some(let state): summary = state.panelSummary
        }

        if summary != lastSummary {
            lastSummary = summary
            stateLabel.label = summary ?? ""
            stateLabel.visible = (summary != nil)
        }

        if machine != nil {
            primaryButton.iconName = "media-playback-stop-symbolic"
            primaryButton.tooltipText = "Stop"
            primaryButton.sensitive = (machine?.state != .starting)
        } else {
            primaryButton.iconName = "media-playback-start-symbolic"
            primaryButton.tooltipText =
                record.hasReadySnapshot ? "Resume where it was marked ready" : "Boot"
            primaryButton.sensitive = true
        }

        refreshScreen()
    }

    private func refreshScreen() {
        let wanted: (any VirtualMachineFrameSource)?
        if !isCollapsed, case .frames(let source)? = machine?.display {
            wanted = source
        } else {
            wanted = nil
        }

        let wantedID = wanted.map { ObjectIdentifier($0) }
        guard wantedID != shownMachineID else { return }
        shownMachineID = wantedID

        while let child = screenHost.firstChild {
            screenHost.remove(child: child)
        }
        screen = nil

        guard let wanted else {
            screenHost.visible = false
            return
        }

        let screen = VirtualMachineScreen(source: wanted)
        self.screen = screen
        screenHost.append(child: screen.widget)
        screenHost.visible = true
    }

    private func presentMenu() {
        guard let engine else { return }
        let machine = self.machine
        let canSnapshot = machine?.capabilities.contains(.snapshot) ?? false

        var running: [ContextMenu.Item] = []
        if let machine {
            running.append(
                ContextMenu.Item("Mark Ready", enabled: canSnapshot) { [weak self] in
                    self?.perform { try await engine.virtualMachines.markReady(machine) }
                })
            running.append(
                ContextMenu.Item(
                    "Back to Ready", enabled: canSnapshot && record.hasReadySnapshot
                ) { [weak self] in
                    self?.perform { try await machine.restoreReadySnapshot() }
                })
        } else if record.hasReadySnapshot {
            running.append(
                ContextMenu.Item("Boot Fresh, Leaving the Snapshot Behind") { [weak self, record] in
                    self?.perform {
                        _ = try await engine.virtualMachines.boot(
                            record, resumingFromReadySnapshot: false)
                    }
                })
        }

        var snapshot: [ContextMenu.Item] = []
        if record.hasReadySnapshot {
            snapshot.append(
                ContextMenu.Item("Forget the Ready Snapshot") { [weak self, record] in
                    self?.perform { try await engine.virtualMachines.discardReadySnapshot(record) }
                })
        }

        let forget = [
            ContextMenu.Item("Forget Machine\u{2026}", destructive: true) { [weak self] in
                self?.confirmForget()
            }
        ]

        ContextMenu.present(
            [running, snapshot, forget],
            at: menuButton,
            x: Double(menuButton.width) / 2,
            y: Double(menuButton.height))
    }

    private func confirmForget() {
        guard let engine else { return }

        let alert = Adw.AlertDialog(
            heading: "Forget Machine?",
            body: "This will stop \u{201c}\(record.name)\u{201d} and delete its snapshot. Its disk image is left alone.")
        alert.addResponse(id: "cancel", label: "_Cancel")
        alert.addResponse(id: "forget", label: "_Forget Machine")
        alert.setResponseAppearance(response: "forget", appearance: .destructive)
        alert.setClose(response: "cancel")
        alert.onResponse { [record] _, responseID in
            MainActor.assumeIsolated {
                guard responseID == "forget" else { return }
                Task { @MainActor in
                    await engine.virtualMachines.forget(record)
                }
            }
        }
        alert.present(parent: widget)
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        onFailure(nil)
        Task { @MainActor in
            do {
                try await work()
            } catch {
                self.onFailure(error.localizedDescription)
            }
            self.refreshState()
        }
    }

    private func performPrimaryAction() {
        guard let engine else { return }
        onFailure(nil)

        if machine != nil {
            Task { @MainActor in
                await engine.virtualMachines.stop(record)
                self.refreshState()
            }
        } else {
            Task { @MainActor in
                do {
                    _ = try await engine.virtualMachines.boot(record)
                } catch {
                    self.onFailure(error.localizedDescription)
                }
                self.refreshState()
            }
        }
    }
}

extension VirtualMachineState {
    var panelSummary: String {
        switch self {
        case .starting: return "Starting…"
        case .installing(let fraction): return "Installing… \(Int(fraction * 100))%"
        case .running: return "Running"
        case .capturingSnapshot: return "Taking a snapshot…"
        case .restoringSnapshot: return "Going back to the snapshot…"
        case .stopped: return "Stopped"
        case .failed(let reason): return reason
        }
    }
}
