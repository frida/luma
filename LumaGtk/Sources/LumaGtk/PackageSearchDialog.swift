import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Gtk
import LumaCore

struct NpmPackageResult: Sendable {
    let name: String
    let version: String
    let descriptionText: String?
}

@MainActor
final class PackageSearchDialog {
    private weak var engine: Engine?
    private weak var hostWindow: Window?
    private var onInstalled: (() -> Void)?

    private let widget: Box
    private let searchEntry: Entry
    private let searchSpinner: Spinner
    private let listBox: ListBox
    private let statusLabel: Label
    private let errorLabel: Label

    private let formBox: Box
    private let versionEntry: Entry
    private let aliasEntry: Entry
    private let installButton: Button
    private let installSpinner: Spinner

    private var results: [NpmPackageResult] = []
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

        searchSpinner = Spinner()
        searchSpinner.spinning = false
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
            MainActor.assumeIsolated { self?.scheduleSearch(debounce: false) }
        }
        searchEntry.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSearch(debounce: true) }
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
            searchSpinner.spinning = false
            searchSpinner.stop()
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
        searchSpinner.spinning = true
        searchSpinner.start()

        searchTask = Task { @MainActor [weak self] in
            let outcome: Result<[NpmPackageResult], Error>
            do {
                let pkgs = try await Self.fetchNpmSearch(query: query, limit: 25)
                outcome = .success(pkgs)
            } catch {
                outcome = .failure(error)
            }

            guard let self else { return }
            if Task.isCancelled || self.currentQuery != query { return }

            self.searchSpinner.spinning = false
            self.searchSpinner.stop()

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

    private static func fetchNpmSearch(query: String, limit: Int) async throws -> [NpmPackageResult] {
        var components = URLComponents(string: "https://registry.npmjs.org/-/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "text", value: "\(query) keywords:frida-gum"),
            URLQueryItem(name: "from", value: "0"),
            URLQueryItem(name: "size", value: String(limit)),
        ]
        guard let url = components.url else {
            throw NSError(domain: "PackageSearchDialog", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(
                domain: "PackageSearchDialog",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from npm registry"])
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]]
        else {
            throw NSError(
                domain: "PackageSearchDialog",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unexpected npm response shape"])
        }

        return objects.compactMap { object -> NpmPackageResult? in
            guard let pkg = object["package"] as? [String: Any],
                  let name = pkg["name"] as? String,
                  let version = pkg["version"] as? String
            else { return nil }
            let desc = pkg["description"] as? String
            return NpmPackageResult(name: name, version: version, descriptionText: desc)
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

    private func onResultSelected(_ pkg: NpmPackageResult) {
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
        cancelButton.onClicked { [window] _ in
            MainActor.assumeIsolated { window.destroy() }
        }
        header.packStart(child: cancelButton)
        window.set(titlebar: WidgetRef(header))

        installEscapeShortcut(on: window)

        window.set(child: dialog.widget)

        dialog.hostWindow = window
        Self.retain(dialog: dialog, window: window)

        installEscapeShortcut(on: window)
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
