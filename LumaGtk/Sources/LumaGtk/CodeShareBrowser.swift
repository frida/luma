import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Gtk
import LumaCore

@MainActor
final class CodeShareBrowser {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private weak var hostWindow: Window?

    private let popularButton: Button
    private let searchButton: Button
    private let searchEntry: Entry
    private let listBox: ListBox
    private let errorLabel: Label
    private let listSpinner: Spinner

    private let detailContainer: Box
    private let detailSpinner: Spinner
    private let titleLabel: Label
    private let ownerLabel: Label
    private let descriptionLabel: Label
    private let sourceEditor: MonacoEditor
    private let sourceContainer: Box
    private let loadingSpinner: Spinner
    private let addButton: Button
    private let detailErrorLabel: Label

    private enum Mode {
        case popular
        case search
    }

    private var mode: Mode = .popular
    private var projects: [CodeShareService.ProjectSummary] = []
    private var selectedIndex: Int? = nil
    private var currentDetails: CodeShareService.ProjectDetails?
    private var currentSource: String = ""

    private var loadTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var isAdding = false

    init(engine: Engine, sessionID: UUID, codeShareEditor: MonacoEditor) {
        self.engine = engine
        self.sessionID = sessionID
        self.sourceEditor = codeShareEditor

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        let toolbar = Box(orientation: .horizontal, spacing: 8)
        toolbar.marginStart = 12
        toolbar.marginEnd = 12
        toolbar.marginTop = 12
        toolbar.marginBottom = 8

        popularButton = Button(label: "Popular")
        searchButton = Button(label: "Search")
        popularButton.add(cssClass: "suggested-action")
        toolbar.append(child: popularButton)
        toolbar.append(child: searchButton)

        searchEntry = Entry()
        searchEntry.placeholderText = "Search CodeShare"
        searchEntry.hexpand = true
        searchEntry.visible = false
        toolbar.append(child: searchEntry)

        listSpinner = Spinner()
        listSpinner.spinning = false
        toolbar.append(child: listSpinner)

        widget.append(child: toolbar)

        errorLabel = Label(str: "")
        errorLabel.halign = .start
        errorLabel.marginStart = 12
        errorLabel.marginEnd = 12
        errorLabel.add(cssClass: "error")
        errorLabel.wrap = true
        errorLabel.visible = false
        widget.append(child: errorLabel)

        let paned = Paned(orientation: .horizontal)
        paned.position = 320
        paned.hexpand = true
        paned.vexpand = true

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")
        let listScroll = ScrolledWindow()
        listScroll.hexpand = true
        listScroll.vexpand = true
        listScroll.set(child: listBox)
        paned.startChild = WidgetRef(listScroll)

        detailContainer = Box(orientation: .vertical, spacing: 8)
        detailContainer.marginStart = 16
        detailContainer.marginEnd = 16
        detailContainer.marginTop = 16
        detailContainer.marginBottom = 16
        detailContainer.hexpand = true
        detailContainer.vexpand = true

        let headerRow = Box(orientation: .horizontal, spacing: 8)
        titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-2")
        titleLabel.selectable = true
        titleLabel.wrap = true
        titleLabel.hexpand = true
        headerRow.append(child: titleLabel)

        detailSpinner = Spinner()
        detailSpinner.spinning = false
        headerRow.append(child: detailSpinner)
        detailContainer.append(child: headerRow)

        ownerLabel = Label(str: "")
        ownerLabel.halign = .start
        ownerLabel.add(cssClass: "dim-label")
        ownerLabel.selectable = true
        detailContainer.append(child: ownerLabel)

        descriptionLabel = Label(str: "Select a snippet to preview and add it as an instrument.")
        descriptionLabel.halign = .start
        descriptionLabel.wrap = true
        descriptionLabel.selectable = true
        detailContainer.append(child: descriptionLabel)

        detailErrorLabel = Label(str: "")
        detailErrorLabel.halign = .start
        detailErrorLabel.add(cssClass: "error")
        detailErrorLabel.wrap = true
        detailErrorLabel.visible = false
        detailContainer.append(child: detailErrorLabel)

        let sourceHeader = Label(str: "Source")
        sourceHeader.halign = .start
        sourceHeader.add(cssClass: "heading")
        sourceHeader.marginTop = 8
        detailContainer.append(child: sourceHeader)

        sourceContainer = Box(orientation: .vertical, spacing: 0)
        sourceContainer.hexpand = true
        sourceContainer.vexpand = true
        sourceContainer.setSizeRequest(width: -1, height: 360)
        detailContainer.append(child: sourceContainer)

        loadingSpinner = Spinner()
        loadingSpinner.halign = .center
        loadingSpinner.valign = .center
        loadingSpinner.hexpand = true
        loadingSpinner.vexpand = true

        let actions = Box(orientation: .horizontal, spacing: 8)
        let actionsSpacer = Label(str: "")
        actionsSpacer.hexpand = true
        actions.append(child: actionsSpacer)

        addButton = Button(label: "Add as Instrument")
        addButton.add(cssClass: "suggested-action")
        addButton.sensitive = false
        actions.append(child: addButton)
        detailContainer.append(child: actions)

        let detailScroll = ScrolledWindow()
        detailScroll.hexpand = true
        detailScroll.vexpand = true
        detailScroll.set(child: detailContainer)
        paned.endChild = WidgetRef(detailScroll)

        widget.append(child: paned)

        popularButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.switchTo(mode: .popular) }
        }
        searchButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.switchTo(mode: .search) }
        }
        searchEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSearch() }
        }
        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let idx = Int(row.index)
                guard idx >= 0, idx < self.projects.count else { return }
                self.selectedIndex = idx
                self.loadDetails(for: self.projects[idx])
            }
        }
        addButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.addAsInstrument() }
        }

        codeShareEditor.setProfile(EditorProfile.fridaCodeShare(readOnly: true))
        codeShareEditor.setText("")
        if codeShareEditor.isReady {
            codeShareEditor.reparent(into: sourceContainer)
        } else {
            loadingSpinner.spinning = true
            loadingSpinner.start()
            sourceContainer.append(child: loadingSpinner)
            codeShareEditor.onReady = { [weak self] in
                guard let self else { return }
                self.sourceContainer.remove(child: self.loadingSpinner)
                self.loadingSpinner.spinning = false
                self.loadingSpinner.stop()
                self.sourceEditor.reparent(into: self.sourceContainer)
            }
        }

        loadPopular()
    }

    fileprivate func setHostWindow(_ window: Window) {
        hostWindow = window
    }

    private func switchTo(mode newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        if newMode == .popular {
            popularButton.add(cssClass: "suggested-action")
            searchButton.remove(cssClass: "suggested-action")
            searchEntry.visible = false
            loadPopular()
        } else {
            searchButton.add(cssClass: "suggested-action")
            popularButton.remove(cssClass: "suggested-action")
            searchEntry.visible = true
            projects = []
            rebuildList()
            clearDetail()
        }
    }

    private func scheduleSearch() {
        guard mode == .search else { return }
        searchDebounceTask?.cancel()
        let query = searchEntry.text ?? ""
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            self.performSearch(query: query)
        }
    }

    private func loadPopular() {
        loadTask?.cancel()
        showError(nil)
        listSpinner.spinning = true
        listSpinner.start()
        loadTask = Task { @MainActor in
            defer {
                listSpinner.spinning = false
                listSpinner.stop()
            }
            do {
                let items = try await CodeShareService.fetchPopular()
                if Task.isCancelled { return }
                guard self.mode == .popular else { return }
                self.projects = items
                self.rebuildList()
            } catch is CancellationError {
                return
            } catch {
                self.projects = []
                self.rebuildList()
                self.showError(String(describing: error))
            }
        }
    }

    private func performSearch(query: String) {
        loadTask?.cancel()
        showError(nil)
        if query.isEmpty {
            projects = []
            rebuildList()
            return
        }
        listSpinner.spinning = true
        listSpinner.start()
        loadTask = Task { @MainActor in
            defer {
                listSpinner.spinning = false
                listSpinner.stop()
            }
            do {
                let items = try await CodeShareService.searchProjects(query: query)
                if Task.isCancelled { return }
                guard self.mode == .search else { return }
                self.projects = items
                self.rebuildList()
            } catch is CancellationError {
                return
            } catch {
                self.projects = []
                self.rebuildList()
                self.showError(String(describing: error))
            }
        }
    }

    private func rebuildList() {
        listBox.removeAll()
        selectedIndex = nil
        clearDetail()
        for project in projects {
            let row = ListBoxRow()
            let column = Box(orientation: .vertical, spacing: 2)
            column.marginStart = 12
            column.marginEnd = 12
            column.marginTop = 6
            column.marginBottom = 6

            let nameLabel = Label(str: project.name)
            nameLabel.halign = .start
            column.append(child: nameLabel)

            let slugLabel = Label(str: "@\(project.owner)/\(project.slug)")
            slugLabel.halign = .start
            slugLabel.add(cssClass: "dim-label")
            column.append(child: slugLabel)

            let likesLabel = Label(str: "♥ \(project.likes)")
            likesLabel.halign = .start
            likesLabel.add(cssClass: "dim-label")
            column.append(child: likesLabel)

            row.set(child: column)
            listBox.append(child: row)
        }
    }

    private func clearDetail() {
        detailsTask?.cancel()
        currentDetails = nil
        currentSource = ""
        titleLabel.setText(str: "")
        ownerLabel.setText(str: "")
        descriptionLabel.setText(str: "Select a snippet to preview and add it as an instrument.")
        sourceEditor.setText("")
        addButton.sensitive = false
        detailErrorLabel.visible = false
        detailSpinner.spinning = false
        detailSpinner.stop()
    }

    private func loadDetails(for project: CodeShareService.ProjectSummary) {
        detailsTask?.cancel()
        currentDetails = nil
        currentSource = ""
        addButton.sensitive = false
        detailErrorLabel.visible = false

        titleLabel.setText(str: project.name)
        ownerLabel.setText(str: "@\(project.owner)/\(project.slug)  •  ♥ \(project.likes)")
        descriptionLabel.setText(str: project.description)
        sourceEditor.setText("")

        detailSpinner.spinning = true
        detailSpinner.start()

        let owner = project.owner
        let slug = project.slug
        detailsTask = Task { @MainActor in
            defer {
                detailSpinner.spinning = false
                detailSpinner.stop()
            }
            do {
                let details = try await CodeShareService.fetchProjectDetails(owner: owner, slug: slug)
                if Task.isCancelled { return }
                guard self.selectedIndex.flatMap({ self.projects.indices.contains($0) ? self.projects[$0] : nil })?.id == project.id else {
                    return
                }
                self.currentDetails = details
                self.currentSource = details.source
                self.descriptionLabel.setText(str: details.description)
                self.sourceEditor.setText(details.source)
                self.addButton.sensitive = true
            } catch is CancellationError {
                return
            } catch {
                self.detailErrorLabel.setText(str: String(describing: error))
                self.detailErrorLabel.visible = true
            }
        }
    }

    private func addAsInstrument() {
        guard !isAdding else { return }
        guard let engine, let details = currentDetails else { return }
        isAdding = true
        addButton.sensitive = false

        let source = currentSource
        let projectRef = CodeShareProjectRef(id: details.id, owner: details.owner, slug: details.slug)
        let hash: String = {
            let data = Data(source.utf8)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }()
        let config = CodeShareConfig(
            name: details.name,
            description: details.description,
            source: source,
            exports: [],
            project: projectRef,
            lastSyncedHash: hash,
            lastReviewedHash: hash,
            fridaVersion: details.fridaVersion,
            allowRemoteUpdates: false
        )

        guard let configData = try? JSONEncoder().encode(config) else {
            isAdding = false
            addButton.sensitive = true
            return
        }

        let sourceIdentifier = "@\(details.owner)/\(details.slug)"
        let descriptor = InstrumentDescriptor(
            id: "codeshare:\(sourceIdentifier)",
            kind: .codeShare,
            sourceIdentifier: sourceIdentifier,
            displayName: config.name,
            icon: .system("cloud"),
            makeInitialConfigJSON: { configData }
        )
        engine.registerDescriptor(descriptor)

        let sid = sessionID
        Task { @MainActor in
            _ = await engine.addInstrument(
                kind: .codeShare,
                sourceIdentifier: sourceIdentifier,
                configJSON: configData,
                sessionID: sid
            )
            self.hostWindow?.destroy()
        }
    }

    private func showError(_ message: String?) {
        if let message {
            errorLabel.setText(str: message)
            errorLabel.visible = true
        } else {
            errorLabel.setText(str: "")
            errorLabel.visible = false
        }
    }

    static func present(from anchor: Widget, engine: Engine, sessionID: UUID, codeShareEditor: MonacoEditor) {
        if let rootPtr = anchor.root?.ptr {
            present(from: WindowRef(raw: rootPtr), engine: engine, sessionID: sessionID, codeShareEditor: codeShareEditor)
        } else {
            present(from: nil as Window?, engine: engine, sessionID: sessionID, codeShareEditor: codeShareEditor)
        }
    }

    static func present(from parent: Window?, engine: Engine, sessionID: UUID, codeShareEditor: MonacoEditor) {
        present(
            from: parent.map { WindowRef(raw: $0.ptr) },
            engine: engine,
            sessionID: sessionID,
            codeShareEditor: codeShareEditor
        )
    }

    static func present(from parent: WindowRef?, engine: Engine, sessionID: UUID, codeShareEditor: MonacoEditor) {
        let browser = CodeShareBrowser(engine: engine, sessionID: sessionID, codeShareEditor: codeShareEditor)

        let window = Window()
        window.title = "CodeShare"
        window.setDefaultSize(width: 900, height: 600)
        window.modal = false
        window.destroyWithParent = true

        if let parent {
            window.setTransientFor(parent: parent)
        }

        let header = HeaderBar()
        let closeButton = Button(label: "Close")
        closeButton.onClicked { [window] _ in
            MainActor.assumeIsolated { window.destroy() }
        }
        header.packEnd(child: closeButton)
        window.set(titlebar: WidgetRef(header))

        window.set(child: browser.widget)

        browser.setHostWindow(window)
        Self.retain(browser: browser, window: window)

        installEscapeShortcut(on: window)
        window.present()
    }

    private static var retained: [ObjectIdentifier: CodeShareBrowser] = [:]

    private static func retain(browser: CodeShareBrowser, window: Window) {
        let key = ObjectIdentifier(window)
        retained[key] = browser
        let handler: (WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }
}
