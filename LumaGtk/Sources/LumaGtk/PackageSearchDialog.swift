import Adw
import Foundation
import Frida
import Gtk
import LumaCore

@MainActor
final class PackageSearchDialog {
    private weak var engine: Engine?
    private weak var hostDialog: Adw.Dialog?
    private var onInstalled: (() -> Void)?

    private let widget: Box
    private let searchEntry: Entry
    private let searchSpinner: Adw.Spinner
    private let listBox: ListBox
    private let statusLabel: Label
    private let errorLabel: Label

    private let specifierEntry: Entry
    private let aliasEntry: Entry
    private let installButton: Button
    private let installSpinner: Adw.Spinner

    private let manager = PackageManager()

    private var results: [Package] = []
    private var selectedIndex: Int? = nil
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isInstalling = false
    private var currentQuery: String = ""

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

        searchSpinner = Adw.Spinner()
        searchSpinner.visible = false
        searchSpinner.setSizeRequest(width: 16, height: 16)
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

        let listRow = Box(orientation: .horizontal, spacing: 8)
        listRow.append(child: listScroll)
        let listTrailingSpacer = Box(orientation: .horizontal, spacing: 0)
        listTrailingSpacer.setSizeRequest(width: 16, height: -1)
        listRow.append(child: listTrailingSpacer)
        widget.append(child: listRow)

        let formBox = Box(orientation: .vertical, spacing: 6)

        let specifierRow = Box(orientation: .horizontal, spacing: 8)
        let specifierLabel = Label(str: "Install:")
        specifierLabel.halign = .start
        specifierLabel.setSizeRequest(width: 140, height: -1)
        specifierRow.append(child: specifierLabel)
        specifierEntry = Entry()
        specifierEntry.placeholderText = "name or name@version"
        specifierEntry.hexpand = true
        specifierRow.append(child: specifierEntry)
        formBox.append(child: specifierRow)

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
        installSpinner = Adw.Spinner()
        installSpinner.visible = false
        installRow.append(child: installSpinner)
        installButton = Button(label: "Add Package")
        installButton.add(cssClass: "suggested-action")
        installButton.sensitive = false
        installRow.append(child: installButton)
        formBox.append(child: installRow)

        widget.append(child: formBox)

        searchEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSearch(debounce: false) }
        }
        searchEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSearch(debounce: true) }
        }
        listBox.onRowSelected { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let row else {
                    self.selectedIndex = nil
                    self.updateInstallButtonSensitivity()
                    return
                }
                let idx = Int(row.index)
                guard idx >= 0, idx < self.results.count else { return }
                self.selectedIndex = idx
                self.onResultSelected(self.results[idx])
            }
        }
        specifierEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInstallButtonSensitivity() }
        }
        installButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.installPackage() }
        }
    }

    deinit {
        searchTask?.cancel()
        debounceTask?.cancel()
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

    private func scheduleSearch(debounce: Bool) {
        let query = (searchEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = query

        debounceTask?.cancel()
        searchTask?.cancel()

        guard !query.isEmpty else {
            showError(nil)
            showStatus(nil)
            results = []
            rebuildList()
            searchSpinner.visible = false
            return
        }

        if debounce {
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                guard let self, self.currentQuery == query else { return }
                self.performSearch(query: query)
            }
        } else {
            performSearch(query: query)
        }
    }

    private func performSearch(query: String) {
        showError(nil)
        showStatus("Searching…")
        searchSpinner.visible = true

        let manager = self.manager
        searchTask = Task { @MainActor [weak self] in
            let outcome: Result<[Package], Swift.Error>
            do {
                let options = PackageSearchOptions()
                options.limit = 25
                let result = try await manager.search(query: query, options: options)
                outcome = .success(result.packages)
            } catch {
                outcome = .failure(error)
            }

            guard let self else { return }
            if Task.isCancelled || self.currentQuery != query { return }

            self.searchSpinner.visible = false

            switch outcome {
            case .success(let pkgs):
                self.results = pkgs
                self.rebuildList()
                if pkgs.isEmpty {
                    self.showStatus("No packages found.")
                } else {
                    self.showStatus("Found \(pkgs.count) packages.")
                }
            case .failure(let error):
                if error is CancellationError { return }
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
        updateInstallButtonSensitivity()

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

    private func onResultSelected(_ pkg: Package) {
        specifierEntry.text = "\(pkg.name)@\(pkg.version)"
        if (aliasEntry.text ?? "").isEmpty, let alias = Self.defaultGlobalAlias(for: pkg.name) {
            aliasEntry.text = alias
        }
        updateInstallButtonSensitivity()
    }

    private func updateInstallButtonSensitivity() {
        let hasSpecifier = !(specifierEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSelection = selectedIndex != nil
        installButton.sensitive = (hasSpecifier || hasSelection) && !isInstalling
    }

    private func installPackage() {
        guard !isInstalling, let engine else { return }

        let rawSpec = (specifierEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let name: String
        let versionSpec: String
        if !rawSpec.isEmpty {
            let parsed = Self.parsePackageSpecifier(rawSpec)
            guard !parsed.name.isEmpty else { return }
            name = parsed.name
            versionSpec = parsed.versionSpec ?? "latest"
        } else if let idx = selectedIndex, idx < results.count {
            let pkg = results[idx]
            name = pkg.name
            versionSpec = pkg.version
        } else {
            return
        }

        let aliasText = (aliasEntry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let alias: String? = aliasText.isEmpty ? nil : aliasText

        isInstalling = true
        updateInstallButtonSensitivity()
        installSpinner.visible = true
        showError(nil)
        showStatus("Installing \(name)@\(versionSpec)…")

        Task { @MainActor in
            defer {
                self.isInstalling = false
                self.installSpinner.visible = false
                self.updateInstallButtonSensitivity()
            }
            do {
                _ = try await engine.installPackage(name: name, versionSpec: versionSpec, globalAlias: alias)
                self.showStatus("Installed \(name)@\(versionSpec).")
                self.onInstalled?()
                _ = self.hostDialog?.close()
            } catch {
                self.showStatus(nil)
                self.showError("Install failed: \(error.localizedDescription)")
            }
        }
    }

    private static func parsePackageSpecifier(_ spec: String) -> (name: String, versionSpec: String?) {
        if let atIndex = spec.lastIndex(of: "@"), atIndex != spec.startIndex {
            let namePart = String(spec[..<atIndex])
            let versionPart = String(spec[spec.index(after: atIndex)...])
            if !namePart.isEmpty, !versionPart.isEmpty {
                return (namePart, versionPart)
            }
        }
        return (spec, nil)
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

        let adwDialog = Adw.Dialog()
        adwDialog.set(title: "Install Package")
        adwDialog.set(contentWidth: 640)
        adwDialog.set(contentHeight: 560)

        let header = Adw.HeaderBar()

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: dialog.widget)
        adwDialog.set(child: toolbarView)

        dialog.hostDialog = adwDialog
        Self.retain(dialog: dialog, adwDialog: adwDialog)

        adwDialog.present(parent: anchor)
    }

    private static var retained: [ObjectIdentifier: PackageSearchDialog] = [:]

    private static func retain(dialog: PackageSearchDialog, adwDialog: Adw.Dialog) {
        let key = ObjectIdentifier(adwDialog)
        retained[key] = dialog
        adwDialog.onClosed { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
        }
    }
}
