import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class MainWindow {
    private let app: Application
    private let window: ApplicationWindow

    private var engine: Engine?

    private let sessionsList: ListBox
    private let packagesList: ListBox
    private let packagesSection: Box
    private let notebookListBox: ListBox
    private let notebookRow: ListBoxRow
    private let detailContainer: Box

    private var sessions: [LumaCore.ProcessSession] = []
    private var installedPackages: [LumaCore.InstalledPackage] = []
    private var selection: SidebarSelection = .notebook

    private enum SidebarSelection: Equatable {
        case notebook
        case session(UUID)
        case package(UUID)
    }

    init(app: Application) {
        self.app = app
        self.window = ApplicationWindow(application: app)
        window.title = "Luma"
        window.setDefaultSize(width: 1200, height: 800)

        let notebookListBox = ListBox()
        let notebookRow = ListBoxRow()
        let sessionsList = ListBox()
        let packagesList = ListBox()
        let packagesSection = Box(orientation: .vertical, spacing: 0)
        let detailContainer = Box(orientation: .vertical, spacing: 0)
        self.notebookListBox = notebookListBox
        self.notebookRow = notebookRow
        self.sessionsList = sessionsList
        self.packagesList = packagesList
        self.packagesSection = packagesSection
        self.detailContainer = detailContainer

        let paned = Paned(orientation: .horizontal)
        paned.position = 280
        paned.startChild = WidgetRef(buildSidebar())
        paned.endChild = WidgetRef(buildDetailPane())
        window.set(child: paned)
    }

    func present() {
        window.present()
        renderDetail()
    }

    func attach(engine: Engine) {
        self.engine = engine
        renderSessions(engine.sessions)
        renderPackages((try? engine.store.fetchPackagesState())?.packages ?? [])
        observeSessions()
    }

    func showFatalError(_ message: String) {
        replaceDetail(with: Label(str: message))
    }

    // MARK: - Sidebar build

    private func buildSidebar() -> ScrolledWindow {
        let column = Box(orientation: .vertical, spacing: 8)
        column.marginTop = 8
        column.marginBottom = 8
        column.hexpand = true
        column.vexpand = true

        column.append(child: buildNotebookSection())
        column.append(child: buildSessionsSection())
        column.append(child: buildPackagesSection())

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: column)
        return scroll
    }

    private func buildNotebookSection() -> Box {
        notebookListBox.selectionMode = .single
        notebookListBox.add(cssClass: "navigation-sidebar")
        notebookListBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard row != nil else { return }
                self?.select(.notebook)
            }
        }

        let label = Label(str: "📓  Notebook")
        label.halign = .start
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 6
        label.marginBottom = 6
        notebookRow.set(child: label)
        notebookListBox.append(child: notebookRow)
        notebookListBox.select(row: notebookRow)

        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.append(child: notebookListBox)
        return wrapper
    }

    private func buildSessionsSection() -> Box {
        sessionsList.selectionMode = .single
        sessionsList.add(cssClass: "navigation-sidebar")
        sessionsList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.sessions.count else { return }
                self.select(.session(self.sessions[index].id))
            }
        }

        let column = Box(orientation: .vertical, spacing: 0)
        column.append(child: sectionHeader("Sessions"))
        column.append(child: sessionsList)
        return column
    }

    private func buildPackagesSection() -> Box {
        packagesList.selectionMode = .single
        packagesList.add(cssClass: "navigation-sidebar")
        packagesList.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let index = Int(row.index)
                guard index >= 0, index < self.installedPackages.count else { return }
                self.select(.package(self.installedPackages[index].id))
            }
        }

        packagesSection.append(child: sectionHeader("Packages"))
        packagesSection.append(child: packagesList)
        packagesSection.visible = false
        return packagesSection
    }

    private func sectionHeader(_ title: String) -> Label {
        let label = Label(str: title.uppercased())
        label.halign = .start
        label.marginStart = 16
        label.marginEnd = 12
        label.marginTop = 12
        label.marginBottom = 4
        label.add(cssClass: "heading")
        return label
    }

    // MARK: - Detail

    private func buildDetailPane() -> ScrolledWindow {
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: detailContainer)
        return scroll
    }

    private func renderDetail() {
        let widget: Widget
        switch selection {
        case .notebook:
            widget = makePlaceholder(
                title: "Notebook",
                subtitle: "Pinned events and notes will appear here."
            )
        case .session(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                let lines = [
                    "Process: \(session.processName)",
                    "Device: \(session.deviceName)",
                    "Phase: \(session.phase)",
                    "Created: \(session.createdAt)",
                ]
                widget = makePlaceholder(title: session.processName, subtitle: lines.joined(separator: "\n"))
            } else {
                widget = makePlaceholder(title: "Session", subtitle: "(no longer in store)")
            }
        case .package(let id):
            if let package = installedPackages.first(where: { $0.id == id }) {
                widget = makePlaceholder(title: package.name, subtitle: "version \(package.version)")
            } else {
                widget = makePlaceholder(title: "Package", subtitle: "(no longer installed)")
            }
        }
        replaceDetail(with: widget)
    }

    private func makePlaceholder(title: String, subtitle: String) -> Box {
        let stack = Box(orientation: .vertical, spacing: 8)
        stack.marginStart = 24
        stack.marginEnd = 24
        stack.marginTop = 24
        stack.marginBottom = 24

        let titleLabel = Label(str: title)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-2")
        stack.append(child: titleLabel)

        let subtitleLabel = Label(str: subtitle)
        subtitleLabel.halign = .start
        subtitleLabel.wrap = true
        stack.append(child: subtitleLabel)

        return stack
    }

    private func replaceDetail<T: WidgetProtocol>(with widget: T) {
        var child = detailContainer.firstChild
        while let current = child {
            child = current.nextSibling
            detailContainer.remove(child: current)
        }
        detailContainer.append(child: widget)
    }

    // MARK: - Selection

    private func select(_ newValue: SidebarSelection) {
        guard selection != newValue else { return }
        selection = newValue
        if newValue != .notebook {
            notebookListBox.unselectAll()
        }
        if case .session = newValue {
            packagesList.unselectAll()
        } else if case .package = newValue {
            sessionsList.unselectAll()
        }
        if case .notebook = newValue {
            sessionsList.unselectAll()
            packagesList.unselectAll()
        }
        renderDetail()
    }

    // MARK: - Engine bindings

    private func observeSessions() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                self.renderSessions(engine.sessions)
                self.observeSessions()
            }
        }
    }

    private func renderSessions(_ snapshot: [LumaCore.ProcessSession]) {
        sessions = snapshot
        sessionsList.removeAll()
        for session in snapshot {
            let row = ListBoxRow()
            let label = Label(str: "\(session.processName) — \(session.deviceName)")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            sessionsList.append(child: row)
        }
        if case .session(let id) = selection,
            !snapshot.contains(where: { $0.id == id })
        {
            select(.notebook)
            notebookListBox.select(row: notebookRow)
        }
    }

    private func renderPackages(_ snapshot: [LumaCore.InstalledPackage]) {
        installedPackages = snapshot
        packagesList.removeAll()
        for package in snapshot {
            let row = ListBoxRow()
            let label = Label(str: "\(package.name)  \(package.version)")
            label.halign = .start
            label.marginStart = 12
            label.marginEnd = 12
            label.marginTop = 4
            label.marginBottom = 4
            row.set(child: label)
            packagesList.append(child: row)
        }
        packagesSection.visible = !snapshot.isEmpty
    }
}
