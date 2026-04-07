import Foundation
import Frida
import Gtk
import LumaCore

@MainActor
final class PackageSearchDialog {
    private weak var engine: Engine?
    private weak var hostWindow: Window?
    private var onInstalled: (() -> Void)?

    private let widget: Box
    private let searchEntry: Entry
    private let searchButton: Button
    private let searchSpinner: Spinner
    private let listBox: ListBox
    private let statusLabel: Label
    private let errorLabel: Label

    private let formBox: Box
    private let versionEntry: Entry
    private let aliasEntry: Entry
    private let installButton: Button
    private let installSpinner: Spinner

    private var results: [Frida.Package] = []
    private var selectedIndex: Int? = nil
    private var searchTask: Task<Void, Never>?
    private var isInstalling = false

    init(engine: Engine) {
        self.engine = engine

        widget = Box(orientation: .vertical, spacing: 8)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12
        widget.hexpand = true
        widget.vexpand = true

        let searchRow = Box(orientation: .horizontal, spacing: 8)
        searchEntry = Entry()
        searchEntry.placeholderText = "Search npm registry…"
        searchEntry.hexpand = true
        searchRow.append(child: searchEntry)

        searchButton = Button(label: "Search")
        searchRow.append(child: searchButton)

        searchSpinner = Spinner()
        searchSpinner.spinning = false
        searchRow.append(child: searchSpinner)
        widget.append(child: searchRow)

        statusLabel = Label(str: "")
        statusLabel.halign = .start
        statusLabel.add(cssClass: "dim-label")
        statusLabel.add(cssClass: "caption")
        statusLabel.wrap = true
        statusLabel.visible = false
        widget.append(child: statusLabel)

        errorLabel = Label(str: "")
        errorLabel.halign = .start
        errorLabel.add(cssClass: "error")
        errorLabel.add(cssClass: "caption")
        errorLabel.wrap = true
        errorLabel.visible = false
        widget.append(child: errorLabel)

        listBox = ListBox()
        listBox.selectionMode = .single
        listBox.add(cssClass: "navigation-sidebar")
        let listScroll = ScrolledWindow()
        listScroll.hexpand = true
        listScroll.vexpand = true
        listScroll.setSizeRequest(width: -1, height: 260)
        listScroll.set(child: listBox)
        widget.append(child: listScroll)

        formBox = Box(orientation: .vertical, spacing: 6)

        let versionRow = Box(orientation: .horizontal, spacing: 8)
        let versionLabel = Label(str: "Version specifier:")
        versionLabel.halign = .start
        versionLabel.setSizeRequest(width: 140, height: -1)
        versionRow.append(child: versionLabel)
        versionEntry = Entry()
        versionEntry.placeholderText = "optional, e.g. ^1.0.0"
        versionEntry.hexpand = true
        versionRow.append(child: versionEntry)
        formBox.append(child: versionRow)

        let aliasRow = Box(orientation: .horizontal, spacing: 8)
        let aliasNameLabel = Label(str: "Global alias:")
        aliasNameLabel.halign = .start
        aliasNameLabel.setSizeRequest(width: 140, height: -1)
        aliasRow.append(child: aliasNameLabel)
        aliasEntry = Entry()
        aliasEntry.placeholderText = "optional, e.g. ObjC"
        aliasEntry.hexpand = true
        aliasRow.append(child: aliasEntry)
        formBox.append(child: aliasRow)

        let installRow = Box(orientation: .horizontal, spacing: 8)
        let spacer = Label(str: "")
        spacer.hexpand = true
        installRow.append(child: spacer)
        installSpinner = Spinner()
        installSpinner.spinning = false
        installRow.append(child: installSpinner)
        installButton = Button(label: "Install")
        installButton.add(cssClass: "suggested-action")
        installButton.sensitive = false
        installRow.append(child: installButton)
        formBox.append(child: installRow)

        formBox.visible = false
        widget.append(child: formBox)

        searchEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.performSearch() }
        }
        searchButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.performSearch() }
        }
        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                let idx = Int(row.index)
                guard idx >= 0, idx < self.results.count else { return }
                self.selectedIndex = idx
                self.onResultSelected(self.results[idx])
            }
        }
        installButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.installSelected() }
        }
    }

    deinit {
        searchTask?.cancel()
    }

    private func showStatus(_ message: String?) {
        if let message {
            statusLabel.setText(str: message)
            statusLabel.visible = true
        } else {
            statusLabel.visible = false
        }
    }

    private func showError(_ message: String?) {
        if let message {
            errorLabel.setText(str: message)
            errorLabel.visible = true
        } else {
            errorLabel.visible = false
        }
    }

    private func performSearch() {
        guard let engine else { return }
        let query = (searchEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            rebuildList()
            showStatus(nil)
            showError(nil)
            return
        }

        searchTask?.cancel()
        showError(nil)
        showStatus("Searching…")
        searchSpinner.spinning = true
        searchSpinner.start()

        let manager = engine.compilerWorkspace.packageManager
        searchTask = Task { @MainActor in
            defer {
                self.searchSpinner.spinning = false
                self.searchSpinner.stop()
            }
            do {
                let options = PackageSearchOptions()
                options.limit = 25
                let result = try await manager.search(query: query, options: options)
                if Task.isCancelled { return }
                self.results = result.packages
                self.rebuildList()
                if result.packages.isEmpty {
                    self.showStatus("No packages found.")
                } else {
                    self.showStatus("Found \(result.packages.count) packages.")
                }
            } catch is CancellationError {
                return
            } catch {
                self.results = []
                self.rebuildList()
                self.showStatus(nil)
                self.showError("Search failed: \(error.localizedDescription)")
            }
        }
    }

    private func rebuildList() {
        listBox.removeAll()
        selectedIndex = nil
        formBox.visible = false
        installButton.sensitive = false

        for pkg in results {
            let row = ListBoxRow()
            let column = Box(orientation: .vertical, spacing: 2)
            column.marginStart = 12
            column.marginEnd = 12
            column.marginTop = 6
            column.marginBottom = 6

            let nameLabel = Label(str: "\(pkg.name)@\(pkg.version)")
            nameLabel.halign = .start
            nameLabel.add(cssClass: "heading")
            column.append(child: nameLabel)

            if let desc = pkg.descriptionText, !desc.isEmpty {
                let descLabel = Label(str: desc)
                descLabel.halign = .start
                descLabel.add(cssClass: "dim-label")
                descLabel.add(cssClass: "caption")
                descLabel.wrap = true
                descLabel.maxWidthChars = 80
                column.append(child: descLabel)
            }

            row.set(child: column)
            listBox.append(child: row)
        }
    }

    private func onResultSelected(_ pkg: Frida.Package) {
        formBox.visible = true
        installButton.sensitive = !isInstalling
        if (versionEntry.text ?? "").isEmpty {
            versionEntry.text = pkg.version
        }
        if (aliasEntry.text ?? "").isEmpty, let alias = Self.defaultGlobalAlias(for: pkg.name) {
            aliasEntry.text = alias
        }
    }

    private func installSelected() {
        guard !isInstalling, let engine, let idx = selectedIndex, idx < results.count else { return }
        let pkg = results[idx]
        let name = pkg.name
        let versionSpec = (versionEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasText = (aliasEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let alias: String? = aliasText.isEmpty ? nil : aliasText
        let spec: String? = versionSpec.isEmpty ? nil : versionSpec

        isInstalling = true
        installButton.sensitive = false
        installSpinner.spinning = true
        installSpinner.start()
        showError(nil)
        showStatus("Installing \(name)\(spec.map { "@\($0)" } ?? "")…")

        Task { @MainActor in
            defer {
                self.isInstalling = false
                self.installButton.sensitive = true
                self.installSpinner.spinning = false
                self.installSpinner.stop()
            }
            do {
                _ = try await engine.installPackage(name: name, versionSpec: spec, globalAlias: alias)
                self.showStatus("Installed \(name).")
                self.onInstalled?()
                self.hostWindow?.destroy()
            } catch {
                self.showStatus(nil)
                self.showError("Install failed: \(error.localizedDescription)")
            }
        }
    }

    private static func defaultGlobalAlias(for name: String) -> String? {
        switch name {
        case "frida-objc-bridge": return "ObjC"
        case "frida-java-bridge": return "Java"
        case "frida-swift-bridge": return "Swift"
        default: return nil
        }
    }

    static func present(from anchor: Widget, engine: Engine, onInstalled: @escaping () -> Void) {
        let dialog = PackageSearchDialog(engine: engine)
        dialog.onInstalled = onInstalled

        let window = Window()
        window.title = "Install Package"
        window.setDefaultSize(width: 640, height: 560)
        window.modal = true
        window.destroyWithParent = true

        if let rootPtr = anchor.root?.ptr {
            window.setTransientFor(parent: WindowRef(raw: rootPtr))
        }

        let header = HeaderBar()
        let cancelButton = Button(label: "Cancel")
        cancelButton.onClicked { [weak window] _ in
            MainActor.assumeIsolated { window?.destroy() }
        }
        header.packStart(child: cancelButton)
        window.set(titlebar: WidgetRef(header))

        window.set(child: dialog.widget)

        dialog.hostWindow = window
        Self.retain(dialog: dialog, window: window)

        window.present()
    }

    private static var retained: [ObjectIdentifier: PackageSearchDialog] = [:]

    private static func retain(dialog: PackageSearchDialog, window: Window) {
        let key = ObjectIdentifier(window)
        retained[key] = dialog
        let handler: (WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }
}
