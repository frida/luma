import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class PackageDetailPane {
    let widget: Box

    var onChanged: (() -> Void)?

    private weak var engine: Engine?
    private var package: InstalledPackage

    private let titleLabel: Label
    private let versionLabel: Label
    private let aliasLabel: Label
    private let upgradeButton: Button
    private let removeButton: Button
    private let busySpinner: Adw.Spinner
    private let statusLabel: Label
    private let errorLabel: Label
    private let filesContainer: Box
    private let filesPlaceholder: Label

    private var isBusy = false
    private var loadFilesTask: Task<Void, Never>?

    init(engine: Engine, package: InstalledPackage) {
        self.engine = engine
        self.package = package

        widget = Box(orientation: .vertical, spacing: 12)
        widget.marginStart = 24
        widget.marginEnd = 24
        widget.marginTop = 24
        widget.marginBottom = 24
        widget.hexpand = true
        widget.vexpand = true

        let header = Box(orientation: .vertical, spacing: 4)
        titleLabel = Label(str: package.name)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-3")
        titleLabel.selectable = true
        header.append(child: titleLabel)

        versionLabel = Label(str: "Installed version \(package.version)")
        versionLabel.halign = .start
        versionLabel.add(cssClass: "caption")
        versionLabel.add(cssClass: "dim-label")
        header.append(child: versionLabel)

        aliasLabel = Label(str: "")
        aliasLabel.halign = .start
        aliasLabel.add(cssClass: "tag")
        aliasLabel.add(cssClass: "caption")
        aliasLabel.visible = false
        header.append(child: aliasLabel)

        widget.append(child: header)

        let actions = Box(orientation: .horizontal, spacing: 8)
        upgradeButton = Button(label: "Upgrade to Latest")
        removeButton = Button(label: "Remove Package")
        removeButton.add(cssClass: "destructive-action")
        busySpinner = Adw.Spinner()
        busySpinner.visible = false
        actions.append(child: upgradeButton)
        actions.append(child: removeButton)
        actions.append(child: busySpinner)
        widget.append(child: actions)

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

        let filesHeader = Label(str: "Files")
        filesHeader.halign = .start
        filesHeader.add(cssClass: "heading")
        filesHeader.marginTop = 8
        widget.append(child: filesHeader)

        filesContainer = Box(orientation: .vertical, spacing: 2)
        filesPlaceholder = Label(str: "Loading files…")
        filesPlaceholder.halign = .start
        filesPlaceholder.add(cssClass: "dim-label")
        filesContainer.append(child: filesPlaceholder)

        let filesScroll = ScrolledWindow()
        filesScroll.hexpand = true
        filesScroll.vexpand = true
        filesScroll.setSizeRequest(width: -1, height: 280)
        filesScroll.set(child: filesContainer)
        widget.append(child: filesScroll)

        applyPackageMetadata()

        upgradeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.upgrade() }
        }
        removeButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.remove() }
        }

        loadFiles()
    }

    deinit {
        loadFilesTask?.cancel()
    }

    private func applyPackageMetadata() {
        titleLabel.setText(str: package.name)
        versionLabel.setText(str: "Installed version \(package.version)")
        if let alias = package.globalAlias, !alias.isEmpty {
            aliasLabel.setText(str: "global: \(alias)")
            aliasLabel.visible = true
        } else {
            aliasLabel.visible = false
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        upgradeButton.sensitive = !busy
        removeButton.sensitive = !busy
        busySpinner.visible = busy
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

    private func upgrade() {
        guard let engine, !isBusy else { return }
        let current = package
        setBusy(true)
        showStatus("Checking for updates for \(current.name)…")
        showError(nil)

        Task { @MainActor in
            defer { self.setBusy(false) }
            do {
                let upgraded = try await engine.upgradePackage(current)
                self.package = upgraded
                self.applyPackageMetadata()
                if upgraded.version == current.version {
                    self.showStatus("\(current.name) is already up to date.")
                } else {
                    self.showStatus("Updated \(current.name) from \(current.version) to \(upgraded.version).")
                }
                self.loadFiles()
                self.onChanged?()
            } catch {
                self.showStatus(nil)
                self.showError("Failed to upgrade: \(error.localizedDescription)")
            }
        }
    }

    private func remove() {
        guard let engine, !isBusy else { return }
        let current = package
        setBusy(true)
        showStatus("Removing \(current.name)…")
        showError(nil)

        Task { @MainActor in
            defer { self.setBusy(false) }
            do {
                try await engine.removePackage(current)
                self.showStatus("Package removed.")
                self.onChanged?()
            } catch {
                self.showStatus(nil)
                self.showError("Failed to remove: \(error.localizedDescription)")
            }
        }
    }

    private func loadFiles() {
        loadFilesTask?.cancel()
        clearFilesContainer()
        filesPlaceholder.setText(str: "Loading files…")
        filesContainer.append(child: filesPlaceholder)

        guard let engine else { return }
        let pkgName = package.name
        loadFilesTask = Task { @MainActor in
            do {
                let paths = try engine.compilerWorkspacePaths()
                let root = try await engine.compilerWorkspace.ensureReady(paths: paths)
                if Task.isCancelled { return }
                let entries = Self.collectFiles(root: root, packageName: pkgName)
                if Task.isCancelled { return }
                self.renderFiles(entries)
            } catch is CancellationError {
                return
            } catch {
                self.clearFilesContainer()
                let label = Label(str: "Failed to load files: \(error.localizedDescription)")
                label.halign = .start
                label.add(cssClass: "error")
                label.wrap = true
                self.filesContainer.append(child: label)
            }
        }
    }

    private nonisolated static func collectFiles(root: URL, packageName: String) -> [(String, Bool)] {
        let fm = FileManager.default
        let packageRoot =
            root
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
        guard fm.fileExists(atPath: packageRoot.path) else { return [] }

        let basePath = packageRoot.path
        var entries: [(String, Bool)] = []

        guard let enumerator = fm.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            guard url.path != basePath else { continue }
            let rel: String
            if url.path.hasPrefix(basePath + "/") {
                rel = String(url.path.dropFirst(basePath.count + 1))
            } else {
                rel = url.lastPathComponent
            }
            if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            let depth = rel.split(separator: "/").count
            if depth > 3 {
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            entries.append((rel, isDir))
        }

        entries.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        return entries
    }

    private func renderFiles(_ entries: [(String, Bool)]) {
        clearFilesContainer()
        if entries.isEmpty {
            let empty = Label(str: "No files found for this package.")
            empty.halign = .start
            empty.add(cssClass: "dim-label")
            filesContainer.append(child: empty)
            return
        }
        for (rel, isDir) in entries {
            let prefix = isDir ? "[dir] " : "      "
            let label = Label(str: "\(prefix)\(rel)")
            label.halign = .start
            label.selectable = true
            label.add(cssClass: "monospace")
            filesContainer.append(child: label)
        }
    }

    private func clearFilesContainer() {
        var child = filesContainer.firstChild
        while let current = child {
            child = current.nextSibling
            filesContainer.remove(child: current)
        }
    }
}
