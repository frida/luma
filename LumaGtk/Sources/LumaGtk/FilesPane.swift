import CLuma
import Foundation
import Gdk
import Gtk
import LumaCore

@MainActor
final class FilesPane {
    let widget: Box
    let sessionID: UUID

    private weak var engine: Engine?
    private let window: Gtk.Window
    private let onError: (String) -> Void
    private let pathEntry: Entry
    private let upButton: Button
    private let pushButton: Button
    private let problemLabel: Label
    private let transferLabel: Label
    private let list: ListBox

    private var roots: RemoteFilesystemRoots?
    private var path = ""
    private var entries: [RemoteFileEntry] = []

    init(engine: Engine, sessionID: UUID, window: Gtk.Window, onError: @escaping (String) -> Void) {
        self.engine = engine
        self.sessionID = sessionID
        self.window = window
        self.onError = onError

        widget = Box(orientation: .vertical, spacing: 6)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12
        widget.hexpand = true
        widget.vexpand = true

        let header = Box(orientation: .horizontal, spacing: 6)

        let goButton = Button(label: "Go")
        header.append(child: goButton)

        upButton = Button()
        upButton.set(iconName: "go-up-symbolic")
        upButton.tooltipText = "Parent directory"
        header.append(child: upButton)

        pathEntry = Entry()
        pathEntry.hexpand = true
        pathEntry.add(cssClass: "monospace")
        header.append(child: pathEntry)

        let refreshButton = Button()
        refreshButton.set(iconName: "view-refresh-symbolic")
        refreshButton.tooltipText = "Refresh"
        header.append(child: refreshButton)

        pushButton = Button(label: "Push File Here…")
        header.append(child: pushButton)

        problemLabel = Label(str: "")
        problemLabel.halign = .start
        problemLabel.wrap = true
        problemLabel.add(cssClass: "error")
        problemLabel.add(cssClass: "caption")
        problemLabel.visible = false

        list = ListBox()
        list.selectionMode = .single
        list.add(cssClass: "boxed-list")
        list.valign = .start

        let scroller = ScrolledWindow()
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.vexpand = true
        scroller.set(child: list)

        transferLabel = Label(str: "")
        transferLabel.halign = .start
        transferLabel.add(cssClass: "dim-label")
        transferLabel.add(cssClass: "caption")
        transferLabel.visible = false

        widget.append(child: header)
        widget.append(child: problemLabel)
        widget.append(child: scroller)
        widget.append(child: transferLabel)

        goButton.onClicked { [weak self] button in
            MainActor.assumeIsolated {
                guard let self else { return }
                ContextMenu.present([self.rootItems()], at: button, x: 0, y: Double(button.height))
            }
        }
        upButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.navigate(to: RemotePath.parent(of: self.path))
            }
        }
        pathEntry.onActivate { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.navigate(to: self.pathEntry.text ?? "")
            }
        }
        refreshButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.navigate(to: self.path)
            }
        }
        pushButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.presentPush() }
        }
        list.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.open(self.entries[Int(row.index)])
            }
        }

        Task { @MainActor [weak self] in
            await self?.start()
        }
    }

    private var node: LumaCore.ProcessNode? {
        engine?.node(forSessionID: sessionID)
    }

    private func rootItems() -> [ContextMenu.Item] {
        guard let roots else { return [] }
        var items: [ContextMenu.Item] = [.init("Root") { [weak self] in self?.navigate(to: roots.root) }]
        if let home = roots.home {
            items.append(.init("Home") { [weak self] in self?.navigate(to: home) })
        }
        if let current = roots.currentDirectory {
            items.append(.init("Current Directory") { [weak self] in self?.navigate(to: current) })
        }
        if let temporary = roots.temporaryDirectory {
            items.append(.init("Temporary Directory") { [weak self] in self?.navigate(to: temporary) })
        }
        return items
    }

    private func start() async {
        guard let node else { return }
        do {
            let roots = try await node.filesystemRoots()
            self.roots = roots
            navigate(to: roots.currentDirectory ?? roots.root)
        } catch {
            showProblem(error.localizedDescription)
        }
    }

    private func navigate(to target: String) {
        guard let node else { return }
        Task { @MainActor [weak self] in
            do {
                let listing = try await node.listDirectory(at: target)
                guard let self else { return }
                self.path = listing.path
                self.pathEntry.text = listing.path
                self.entries = listing.entries.sorted(by: RemoteFileEntry.directoriesFirst)
                self.upButton.sensitive = RemotePath.parent(of: listing.path) != listing.path
                self.showProblem(nil)
                self.render()
            } catch {
                self?.showProblem("\(target): \(error.localizedDescription)")
            }
        }
    }

    private func render() {
        while let child = list.firstChild {
            list.remove(child: child)
        }
        for entry in entries {
            list.append(child: makeRow(entry))
        }
    }

    private func makeRow(_ entry: RemoteFileEntry) -> ListBoxRow {
        let box = Box(orientation: .horizontal, spacing: 10)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 6
        box.marginBottom = 6

        let icon = Gtk.Image(iconName: entry.iconName)
        icon.pixelSize = 16
        icon.add(cssClass: "dim-label")
        box.append(child: icon)

        let name = Label(str: entry.target.map { "\(entry.name) → \($0.path)" } ?? entry.name)
        name.halign = .start
        name.hexpand = true
        name.ellipsize = .middle
        box.append(child: name)

        for text in [entry.sizeDescription, entry.modifiedDescription, entry.permissions, "\(entry.owner):\(entry.group)"] {
            let label = Label(str: text)
            label.add(cssClass: "dim-label")
            label.add(cssClass: "caption")
            label.add(cssClass: "monospace")
            label.halign = .end
            box.append(child: label)
        }

        let row = ListBoxRow()
        row.activatable = true
        row.set(child: box)
        attachContextMenu(to: row, entry: entry)
        return row
    }

    private func attachContextMenu(to row: ListBoxRow, entry: RemoteFileEntry) {
        let click = GestureClick()
        click.set(button: 3)
        click.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                var items: [ContextMenu.Item] = []
                if entry.opensAsDirectory {
                    items.append(.init("Open") { [weak self] in self?.open(entry) })
                }
                if entry.kind == .file || entry.target?.kind == .file {
                    items.append(.init("Pull…") { [weak self] in self?.presentPull(entry) })
                }
                items.append(.init("Copy Path") { [weak self] in self?.copyPath(of: entry) })
                ContextMenu.present([items], at: gesture.widget!, x: x, y: y)
            }
        }
        row.add(controller: click)
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.opensAsDirectory {
            navigate(to: RemotePath.join(path, entry.name))
        } else {
            presentPull(entry)
        }
    }

    private func presentPull(_ entry: RemoteFileEntry) {
        let parentPtr = UnsafeMutableRawPointer(window.window_ptr!)
        let request = PullRequest(pane: self, remotePath: RemotePath.join(path, entry.name), name: entry.name)
        let context = Unmanaged.passRetained(request).toOpaque()
        "Pull File".withCString { title in
            entry.name.withCString { name in
                luma_file_dialog_save(parentPtr, title, name, filesPullThunk, context)
            }
        }
    }

    fileprivate func pull(_ remotePath: String, name: String, toPath destination: String?) {
        guard let destination, let node else { return }
        Task { @MainActor [weak self] in
            var received: Int64 = 0
            self?.showTransfer("Pulling \(name)…")
            do {
                try await node.pullFile(at: remotePath, to: URL(fileURLWithPath: destination)) { count in
                    received += count
                    self?.showTransfer("Pulling \(name)… \(RemoteFileEntry.describe(bytes: received))")
                }
                self?.showTransfer(nil)
            } catch {
                self?.showTransfer(nil)
                self?.onError("\(name): \(error.localizedDescription)")
            }
        }
    }

    private func presentPush() {
        let parentPtr = UnsafeMutableRawPointer(window.window_ptr!)
        let context = Unmanaged.passRetained(self).toOpaque()
        "Push File".withCString { title in
            luma_file_dialog_open(parentPtr, title, filesPushThunk, context)
        }
    }

    fileprivate func push(fromPath source: String?) {
        guard let source, let node else { return }
        let url = URL(fileURLWithPath: source)
        let remotePath = RemotePath.join(path, url.lastPathComponent)
        Task { @MainActor [weak self] in
            var sent: Int64 = 0
            self?.showTransfer("Pushing \(url.lastPathComponent)…")
            do {
                try await node.pushFile(from: url, to: remotePath) { count in
                    sent += count
                    self?.showTransfer("Pushing \(url.lastPathComponent)… \(RemoteFileEntry.describe(bytes: sent))")
                }
                guard let self else { return }
                self.showTransfer(nil)
                self.navigate(to: self.path)
            } catch {
                self?.showTransfer(nil)
                self?.onError("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func copyPath(of entry: RemoteFileEntry) {
        guard let display = Display.getDefault() else { return }
        display.clipboard.set(text: RemotePath.join(path, entry.name))
    }

    private func showProblem(_ message: String?) {
        problemLabel.setText(str: message ?? "")
        problemLabel.visible = message != nil
    }

    private func showTransfer(_ message: String?) {
        transferLabel.setText(str: message ?? "")
        transferLabel.visible = message != nil
    }
}

private final class PullRequest {
    let pane: FilesPane
    let remotePath: String
    let name: String

    init(pane: FilesPane, remotePath: String, name: String) {
        self.pane = pane
        self.remotePath = remotePath
        self.name = name
    }
}

private let filesPullThunk: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pathPtr, userData in
    let path = pathPtr.map { String(cString: $0) }
    let request = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let pull = Unmanaged<PullRequest>.fromOpaque(UnsafeMutableRawPointer(bitPattern: request)!).takeRetainedValue()
        pull.pane.pull(pull.remotePath, name: pull.name, toPath: path)
    }
}

private let filesPushThunk: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pathPtr, userData in
    let path = pathPtr.map { String(cString: $0) }
    let pane = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        Unmanaged<FilesPane>.fromOpaque(UnsafeMutableRawPointer(bitPattern: pane)!).takeRetainedValue().push(fromPath: path)
    }
}

extension RemoteFileEntry {
    fileprivate var iconName: String {
        switch target?.kind ?? kind {
        case .directory:
            return "folder-symbolic"
        case .file:
            return "text-x-generic-symbolic"
        case .symlink:
            return "emblem-symbolic-link"
        case .characterDevice, .blockDevice:
            return "drive-harddisk-symbolic"
        case .fifo, .socket:
            return "network-wired-symbolic"
        }
    }

    fileprivate var sizeDescription: String {
        kind == .file ? Self.describe(bytes: Int64(size)) : ""
    }

    fileprivate var modifiedDescription: String {
        modifiedAt.formatted(date: .numeric, time: .shortened)
    }

    fileprivate static func describe(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    fileprivate static func directoriesFirst(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
        if lhs.opensAsDirectory != rhs.opensAsDirectory {
            return lhs.opensAsDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
