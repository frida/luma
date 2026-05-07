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
    private let sectionBar: Box
    private let summaryButton: ToggleButton
    private let modulesButton: ToggleButton
    private let threadsButton: ToggleButton
    private let contentSlot: Box

    private let summaryPane: Box
    private let summaryBox: Box

    private let modulesPane: Paned
    private let modulesList: ListBox
    private let moduleDetailContainer: Box
    private var moduleDetail: ModuleSymbolsPane?

    private let threadsPane: Paned
    private let threadsList: ListBox
    private let threadDetailContainer: Box
    private var threadDetail: ThreadDetailPane?

    private var modulesTask: Task<Void, Never>?
    private var threadsTask: Task<Void, Never>?

    private var currentSortedModules: [LumaCore.ProcessModule] = []
    private var currentSortedThreads: [LumaCore.ProcessThread] = []

    private enum Section {
        case summary
        case modules
        case threads
    }
    private var section: Section = .summary

    init(engine: Engine, session: LumaCore.ProcessSession) {
        self.engine = engine
        self.sessionID = session.id

        widget = Box(orientation: .vertical, spacing: 12)
        widget.marginStart = 16
        widget.marginEnd = 16
        widget.marginTop = 16
        widget.marginBottom = 16
        widget.hexpand = true
        widget.vexpand = true

        titleLabel = Label(str: session.processName)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-2")

        summaryButton = ToggleButton()
        summaryButton.label = "Summary"
        summaryButton.active = true

        modulesButton = ToggleButton()
        modulesButton.label = "Modules"
        modulesButton.set(group: summaryButton)

        threadsButton = ToggleButton()
        threadsButton.label = "Threads"
        threadsButton.set(group: summaryButton)

        sectionBar = Box(orientation: .horizontal, spacing: 0)
        sectionBar.add(cssClass: "linked")
        sectionBar.halign = .start
        sectionBar.append(child: summaryButton)
        sectionBar.append(child: modulesButton)
        sectionBar.append(child: threadsButton)

        contentSlot = Box(orientation: .vertical, spacing: 0)
        contentSlot.hexpand = true
        contentSlot.vexpand = true

        summaryBox = Box(orientation: .vertical, spacing: 4)
        summaryBox.halign = .start

        let summaryScroll = ScrolledWindow()
        summaryScroll.hexpand = true
        summaryScroll.vexpand = true
        summaryScroll.set(child: summaryBox)
        summaryPane = Box(orientation: .vertical, spacing: 0)
        summaryPane.hexpand = true
        summaryPane.vexpand = true
        summaryPane.append(child: summaryScroll)

        modulesList = ListBox()
        modulesList.selectionMode = .single
        modulesList.add(cssClass: "boxed-list")
        let modulesScroll = ScrolledWindow()
        modulesScroll.hexpand = true
        modulesScroll.vexpand = true
        modulesScroll.set(child: modulesList)

        moduleDetailContainer = Box(orientation: .vertical, spacing: 0)
        moduleDetailContainer.hexpand = true
        moduleDetailContainer.vexpand = true

        modulesPane = Paned(orientation: .horizontal)
        modulesPane.startChild = WidgetRef(modulesScroll)
        modulesPane.endChild = WidgetRef(moduleDetailContainer)
        modulesPane.position = 360
        modulesPane.resizeStartChild = true
        modulesPane.resizeEndChild = true
        modulesPane.shrinkStartChild = false
        modulesPane.shrinkEndChild = false
        modulesPane.hexpand = true
        modulesPane.vexpand = true

        threadsList = ListBox()
        threadsList.selectionMode = .single
        threadsList.add(cssClass: "boxed-list")
        let threadsScroll = ScrolledWindow()
        threadsScroll.hexpand = true
        threadsScroll.vexpand = true
        threadsScroll.set(child: threadsList)

        threadDetailContainer = Box(orientation: .vertical, spacing: 0)
        threadDetailContainer.hexpand = true
        threadDetailContainer.vexpand = true

        threadsPane = Paned(orientation: .horizontal)
        threadsPane.startChild = WidgetRef(threadsScroll)
        threadsPane.endChild = WidgetRef(threadDetailContainer)
        threadsPane.position = 320
        threadsPane.resizeStartChild = true
        threadsPane.resizeEndChild = true
        threadsPane.shrinkStartChild = false
        threadsPane.shrinkEndChild = false
        threadsPane.hexpand = true
        threadsPane.vexpand = true

        widget.append(child: titleLabel)
        widget.append(child: sectionBar)
        widget.append(child: contentSlot)

        rebuildSummary(session: session)
        showSection(.summary)
        observeNode()

        summaryButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.summaryButton.active else { return }
                self.showSection(.summary)
            }
        }
        modulesButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.modulesButton.active else { return }
                self.showSection(.modules)
            }
        }
        threadsButton.onToggled { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.threadsButton.active else { return }
                self.showSection(.threads)
            }
        }

        modulesList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.currentSortedModules.count else { return }
                self.showModuleDetail(self.currentSortedModules[index])
            }
        }

        threadsList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.currentSortedThreads.count else { return }
                self.showThreadDetail(self.currentSortedThreads[index])
            }
        }
    }

    deinit {
        modulesTask?.cancel()
        threadsTask?.cancel()
    }

    private func showSection(_ next: Section) {
        section = next
        clearBox(contentSlot)
        switch next {
        case .summary: contentSlot.append(child: summaryPane)
        case .modules: contentSlot.append(child: modulesPane)
        case .threads: contentSlot.append(child: threadsPane)
        }
    }

    private func observeNode() {
        guard let node = engine?.node(forSessionID: sessionID) else {
            renderModules([])
            renderThreads(persistedThreads())
            return
        }

        renderModules(node.modules)
        renderThreads(node.threads)

        modulesTask = Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await _ in node.moduleDeltas {
                self?.renderModules(node.modules)
            }
        }

        threadsTask = Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await _ in node.threadDeltas {
                self?.renderThreads(node.threads)
            }
        }
    }

    private func rebuildSummary(session: LumaCore.ProcessSession) {
        clearBox(summaryBox)

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
            appendSummary(label: "Base", value: String(format: "0x%llx", main.base))
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
        key.setSizeRequest(width: 140, height: -1)
        key.add(cssClass: "dim-label")

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

    private func renderModules(_ modules: [LumaCore.ProcessModule]) {
        let sorted = modules.sorted(by: { $0.base < $1.base })
        currentSortedModules = sorted
        modulesButton.label = "Modules (\(modules.count))"
        clearListBox(modulesList)

        if modules.isEmpty {
            modulesList.append(child: makeEmptyRow(text: "No modules loaded."))
            clearBox(moduleDetailContainer)
            return
        }

        for module in sorted {
            let row = Adw.ActionRow()
            row.set(title: module.name)
            row.set(subtitle: String(format: "0x%llx · %@ bytes", module.base, formatNumber(module.size)))
            modulesList.append(child: row)
        }
    }

    private func renderThreads(_ threads: [LumaCore.ProcessThread]) {
        let sorted = threads.sorted(by: { $0.id < $1.id })
        currentSortedThreads = sorted
        threadsButton.label = "Threads (\(threads.count))"
        clearListBox(threadsList)

        if threads.isEmpty {
            threadsList.append(child: makeEmptyRow(text: "No threads observed."))
            clearBox(threadDetailContainer)
            return
        }

        for thread in sorted {
            let row = Adw.ActionRow()
            row.set(title: thread.name ?? "tid \(thread.id)")
            var subtitle = "tid \(thread.id)"
            if let entry = thread.entrypoint {
                subtitle += String(format: " · entry 0x%llx", entry.routine)
            }
            row.set(subtitle: subtitle)
            threadsList.append(child: row)
            attachThreadContextMenu(to: row, thread: thread)
        }
    }

    private func showModuleDetail(_ module: LumaCore.ProcessModule) {
        clearBox(moduleDetailContainer)
        guard let engine else { return }
        let pane = ModuleSymbolsPane(engine: engine, sessionID: sessionID, module: module)
        moduleDetail = pane
        moduleDetailContainer.append(child: pane.widget)
    }

    private func showThreadDetail(_ thread: LumaCore.ProcessThread) {
        clearBox(threadDetailContainer)
        guard let engine else { return }
        let pane = ThreadDetailPane(engine: engine, sessionID: sessionID, thread: thread)
        threadDetail = pane
        threadDetailContainer.append(child: pane.widget)
    }

    private func attachThreadContextMenu(to anchor: Widget, thread: LumaCore.ProcessThread) {
        guard let engine else { return }
        let actions = engine.threadActions(sessionID: sessionID, thread: thread)
        guard !actions.isEmpty else { return }

        let gesture = GestureClick()
        gesture.set(button: 3)
        gesture.propagationPhase = GTK_PHASE_CAPTURE
        gesture.onPressed { [anchor] _, _, x, y in
            MainActor.assumeIsolated {
                let items: [ContextMenu.Item] = actions.map { action in
                    ContextMenu.Item(action.title, destructive: action.role == .destructive) {
                        Task { @MainActor in
                            if let target = await action.perform() {
                                AddressActionMenu.navigateToTarget?(target)
                            }
                        }
                    }
                }
                ContextMenu.present([items], at: anchor, x: x, y: y)
            }
        }
        anchor.install(controller: gesture)
    }

    private func makeEmptyRow(text: String) -> ListBoxRow {
        let row = ListBoxRow()
        row.selectable = false
        let label = Label(str: text)
        label.halign = .start
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 8
        label.marginBottom = 8
        label.add(cssClass: "dim-label")
        row.set(child: label)
        return row
    }

    private func clearListBox(_ list: ListBox) {
        var child = list.firstChild
        while let current = child {
            child = current.nextSibling
            list.remove(child: current)
        }
    }

    private func clearBox(_ box: Box) {
        var child = box.firstChild
        while let current = child {
            child = current.nextSibling
            box.remove(child: current)
        }
    }

    private func persistedThreads() -> [LumaCore.ProcessThread] {
        engine?.session(id: sessionID)?.lastKnownThreads ?? []
    }

    private func formatNumber(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
