import Adw
import CGtk
import Foundation
import Gdk
import GIO
import GLibObject
import Gtk
import LumaCore
import Observation

@MainActor
final class FilesPane {
    let widget: Box
    let toolbar: Box
    let sessionID: UUID

    private weak var engine: Engine?
    private let window: Gtk.Window
    private let onError: (String) -> Void
    private let pathEntry: Entry
    private let upButton: Button
    private let uploadButton: Button
    private let problemLabel: Label
    private let list: ListBox
    private let dropZone: Box
    private let dropZoneLabel: Label
    private let transferList: Box

    private var roots: RemoteFilesystemRoots?
    private var loadedNodeID: UUID?
    private var path = ""
    private var entries: [RemoteFileEntry] = []
    private var rows: [ListBoxRow] = []
    private var transferRows: [UUID: FileTransferRow] = [:]

    init(engine: Engine, sessionID: UUID, window: Gtk.Window, onError: @escaping (String) -> Void) {
        self.engine = engine
        self.sessionID = sessionID
        self.window = window
        self.onError = onError

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        toolbar = Box(orientation: .horizontal, spacing: 6)
        toolbar.add(cssClass: "toolbar")
        toolbar.marginStart = 6
        toolbar.marginEnd = 6

        let goButton = Button(label: "Go")
        toolbar.append(child: goButton)

        upButton = Button()
        upButton.set(iconName: "go-up-symbolic")
        upButton.tooltipText = "Parent directory"
        toolbar.append(child: upButton)

        pathEntry = Entry()
        pathEntry.hexpand = true
        pathEntry.add(cssClass: "monospace")
        toolbar.append(child: pathEntry)

        let refreshButton = Button()
        refreshButton.set(iconName: "view-refresh-symbolic")
        refreshButton.tooltipText = "Refresh"
        toolbar.append(child: refreshButton)

        uploadButton = Button(label: "Upload…")
        toolbar.append(child: uploadButton)

        problemLabel = Label(str: "")
        problemLabel.halign = .start
        problemLabel.wrap = true
        problemLabel.add(cssClass: "error")
        problemLabel.add(cssClass: "caption")
        problemLabel.visible = false

        list = ListBox()
        list.selectionMode = .multiple
        list.add(cssClass: "boxed-list")
        list.valign = .start

        let scroller = ScrolledWindow()
        scroller.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroller.vexpand = true
        scroller.set(child: list)

        let dropIcon = Gtk.Image(iconName: "document-send-symbolic")
        dropIcon.pixelSize = 48

        dropZoneLabel = Label(str: "")
        dropZoneLabel.add(cssClass: "title-4")
        dropZoneLabel.ellipsize = .middle

        let dropPrompt = Box(orientation: .vertical, spacing: 12)
        dropPrompt.valign = .center
        dropPrompt.vexpand = true
        dropPrompt.append(child: dropIcon)
        dropPrompt.append(child: dropZoneLabel)

        dropZone = Box(orientation: .vertical, spacing: 0)
        dropZone.add(cssClass: "luma-drop-zone")
        dropZone.canTarget = false
        dropZone.visible = false
        dropZone.append(child: dropPrompt)

        let listArea = Overlay()
        listArea.vexpand = true
        listArea.set(child: scroller)
        listArea.addOverlay(widget: dropZone)

        transferList = Box(orientation: .vertical, spacing: 6)
        transferList.visible = false

        let content = Box(orientation: .vertical, spacing: 6)
        content.marginStart = 12
        content.marginEnd = 12
        content.marginBottom = 12
        content.vexpand = true
        content.append(child: problemLabel)
        content.append(child: listArea)
        content.append(child: transferList)

        widget.append(child: content)

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
        uploadButton.onClicked { [weak self] button in
            MainActor.assumeIsolated {
                guard let self else { return }
                ContextMenu.present([self.uploadItems()], at: button, x: 0, y: Double(button.height))
            }
        }
        list.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.open(self.entries[Int(row.index)])
            }
        }
        installDropTarget(on: listArea)
        installDragSource()
        installDeleteKey()

        applySessionState()
    }

    func applySessionState() {
        guard engine?.session(id: sessionID)?.phase == .attached, let node, node.id != loadedNodeID else { return }
        loadedNodeID = node.id
        observeTransfers(of: node)
        _Concurrency.Task { @MainActor [weak self] in
            await self?.start()
        }
    }

    private var node: LumaCore.ProcessNode? {
        engine?.node(forSessionID: sessionID)
    }

    private var acceptsUploads: Bool {
        node != nil && !path.isEmpty
    }

    private var selectedEntries: [RemoteFileEntry] {
        zip(entries, rows).filter { $0.1.isSelected }.map(\.0)
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

    private func uploadItems() -> [ContextMenu.Item] {
        [
            .init("Files…", enabled: acceptsUploads) { [weak self] in self?.presentUpload(.files) },
            .init("Folders…", enabled: acceptsUploads) { [weak self] in self?.presentUpload(.folders) },
        ]
    }

    private func installDropTarget(on area: Overlay) {
        let target = DropTarget(type: gdk_file_list_get_type(), actions: .copy)
        target.onEnter { [weak self] target, _, _ in
            let isForeign = target.currentDrop.drag == nil
            let accepted = MainActor.assumeIsolated {
                guard let self, self.acceptsUploads, isForeign else { return false }
                self.showDropZone(true)
                return true
            }
            return accepted ? .copy : []
        }
        target.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.showDropZone(false) }
        }
        target.onDrop { [weak self] _, value, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return false }
                self.showDropZone(false)
                self.upload(Self.paths(in: value))
                return true
            }
        }
        area.add(controller: target)
    }

    private func installDragSource() {
        let source = DragSource()
        source.set(actions: .copy)
        source.onPrepare { [weak self] _, _, y in
            let provider = MainActor.assumeIsolated { UInt(bitPattern: self?.prepareDrag(atY: y)?.handle) }
            return UnsafeMutableRawPointer(bitPattern: provider).map(Gdk.ContentProviderRef.init(raw:))
        }
        list.add(controller: source)
    }

    private func installDeleteKey() {
        let keys = EventControllerKey()
        keys.onKeyPressed { [weak self] _, keyval, _, _ in
            MainActor.assumeIsolated {
                guard let self, Int32(keyval) == Gdk.keyDelete, !self.selectedEntries.isEmpty else { return false }
                self.confirmDeletion(of: self.selectedEntries)
                return true
            }
        }
        list.add(controller: keys)
    }

    private func observeTransfers(of node: LumaCore.ProcessNode) {
        withObservationTracking {
            renderTransfers(node.fileTransfers)
        } onChange: { [weak self] in
            _Concurrency.Task { @MainActor in
                guard let self, self.node === node else { return }
                self.observeTransfers(of: node)
            }
        }
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
        _Concurrency.Task { @MainActor [weak self] in
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
        rows = entries.map(makeRow)
        for row in rows {
            list.append(child: row)
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
        click.onPressed { [weak self, weak row] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let row else { return }
                if !row.isSelected {
                    self.list.unselectAll()
                    self.list.select(row: row)
                }
                ContextMenu.present(self.contextSections(for: self.selectedEntries), at: gesture.widget!, x: x, y: y)
            }
        }
        row.add(controller: click)
    }

    private func contextSections(for selected: [RemoteFileEntry]) -> [[ContextMenu.Item]] {
        var items: [ContextMenu.Item] = []
        if selected.count == 1, selected[0].opensAsDirectory {
            items.append(.init("Open") { [weak self] in self?.open(selected[0]) })
        }
        if selected.allSatisfy(\.isDownloadable) {
            items.append(.init("Download…") { [weak self] in self?.presentDownload(selected) })
        }
        if selected.count == 1 {
            items.append(.init("Copy Path") { [weak self] in self?.copyPath(of: selected[0]) })
        }
        let deletion: [ContextMenu.Item] = [.init("Delete…", destructive: true) { [weak self] in self?.confirmDeletion(of: selected) }]
        return [items, deletion]
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.opensAsDirectory {
            navigate(to: RemotePath.join(path, entry.name))
        } else {
            presentDownload([entry])
        }
    }

    private func presentDownload(_ selected: [RemoteFileEntry]) {
        let remotePaths = selected.map { RemotePath.join(path, $0.name) }
        let finish: ([String]) -> Void = { [weak self] paths in
            guard let destination = paths.first else { return }
            self?.download(remotePaths, toPath: destination)
        }
        if selected.count == 1 {
            FileDialogRequest.present(.saveAs, title: "Download", initialName: selected[0].name, parent: window, completion: finish)
        } else {
            FileDialogRequest.present(.folder, title: "Download Into", parent: window, completion: finish)
        }
    }

    private func download(_ remotePaths: [String], toPath destination: String) {
        guard let node else { return }
        let destinationURL = URL(fileURLWithPath: destination)
        if remotePaths.count == 1 {
            watch(node.download(remotePaths[0], to: destinationURL))
        } else {
            watch(node.download(remotePaths, into: destinationURL))
        }
    }

    private func presentUpload(_ kind: UploadKind) {
        FileDialogRequest.present(kind.choice, title: kind.title, acceptLabel: "Upload", parent: window) { [weak self] paths in
            guard !paths.isEmpty else { return }
            self?.upload(paths)
        }
    }

    private func upload(_ sources: [String]) {
        guard let node else { return }
        watch(node.upload(sources.map { URL(fileURLWithPath: $0) }, into: path)) { [weak self] in
            guard let self else { return }
            self.navigate(to: self.path)
        }
    }

    private func watch(_ transfer: RemoteFileTransfer, then finish: @escaping () -> Void = {}) {
        _Concurrency.Task { @MainActor [weak self] in
            do {
                try await transfer.waitUntilFinished()
            } catch {
                if !(error is CancellationError) {
                    self?.onError("\(transfer.subject): \(error.localizedDescription)")
                }
            }
            finish()
        }
    }

    private func confirmDeletion(of doomed: [RemoteFileEntry]) {
        let heading = doomed.count == 1 ? "Delete “\(doomed[0].name)”?" : "Delete \(doomed.count) items?"
        let dialog = Adw.AlertDialog(heading: heading, body: "This can’t be undone.")
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "delete", label: "_Delete")
        dialog.setResponseAppearance(response: "delete", appearance: .destructive)
        dialog.setDefault(response: "cancel")
        dialog.setClose(response: "cancel")
        dialog.onResponse { [weak self] _, responseID in
            MainActor.assumeIsolated {
                guard responseID == "delete" else { return }
                self?.delete(doomed)
            }
        }
        dialog.present(parent: widget)
    }

    private func delete(_ doomed: [RemoteFileEntry]) {
        guard let node else { return }
        let remotePaths = doomed.map { RemotePath.join(path, $0.name) }
        _Concurrency.Task { @MainActor [weak self] in
            do {
                try await node.removeItems(at: remotePaths)
            } catch {
                self?.onError(error.localizedDescription)
            }
            guard let self else { return }
            self.navigate(to: self.path)
        }
    }

    private func prepareDrag(atY y: Double) -> DragDownload? {
        guard let node, let row = list.getRowAt(y: Int(y)) else { return nil }
        let index = Int(row.index)
        let dragged = rows[index].isSelected ? selectedEntries : [entries[index]]
        guard dragged.allSatisfy(\.isDownloadable) else { return nil }
        return DragDownload(node: node, remotePaths: dragged.map { RemotePath.join(path, $0.name) })
    }

    private func copyPath(of entry: RemoteFileEntry) {
        guard let display = Display.getDefault() else { return }
        display.clipboard.set(text: RemotePath.join(path, entry.name))
    }

    private func renderTransfers(_ transfers: [RemoteFileTransfer]) {
        let current = Set(transfers.map(\.id))
        for (id, row) in transferRows where !current.contains(id) {
            transferList.remove(child: row.widget)
            transferRows[id] = nil
        }
        for transfer in transfers where transferRows[transfer.id] == nil {
            let row = FileTransferRow(transfer: transfer)
            transferRows[transfer.id] = row
            transferList.append(child: row.widget)
        }
        transferList.visible = !transfers.isEmpty
    }

    private func showDropZone(_ visible: Bool) {
        dropZoneLabel.setText(str: "Upload to \(path)")
        dropZone.visible = visible
    }

    private func showProblem(_ message: String?) {
        problemLabel.setText(str: message ?? "")
        problemLabel.visible = message != nil
    }

    private static func paths(in value: GLibObject.ValueRef) -> [String] {
        Gdk.FileListRef(raw: value.boxed!).getFiles().compactMap { $0.getPath() }
    }

    private enum UploadKind {
        case files
        case folders

        var title: String {
            switch self {
            case .files:
                return "Upload Files"
            case .folders:
                return "Upload Folders"
            }
        }

        var choice: FileDialogRequest.Choice {
            switch self {
            case .files:
                return .files
            case .folders:
                return .folders
            }
        }
    }
}

@MainActor
private final class FileTransferRow {
    let widget: Box

    private let transfer: RemoteFileTransfer
    private let activityLabel: Label
    private let progressBar: ProgressBar
    private let progressLabel: Label

    init(transfer: RemoteFileTransfer) {
        self.transfer = transfer

        widget = Box(orientation: .horizontal, spacing: 10)

        let icon = Gtk.Image(iconName: transfer.direction == .upload ? "go-up-symbolic" : "go-down-symbolic")
        icon.add(cssClass: "dim-label")
        widget.append(child: icon)

        activityLabel = Label(str: transfer.activityDescription)
        activityLabel.halign = .start
        activityLabel.ellipsize = .middle
        activityLabel.add(cssClass: "caption")

        progressBar = ProgressBar()

        progressLabel = Label(str: "")
        progressLabel.halign = .start
        progressLabel.ellipsize = .middle
        progressLabel.add(cssClass: "caption")
        progressLabel.add(cssClass: "dim-label")

        let details = Box(orientation: .vertical, spacing: 4)
        details.hexpand = true
        details.append(child: activityLabel)
        details.append(child: progressBar)
        details.append(child: progressLabel)
        widget.append(child: details)

        let cancelButton = Button()
        cancelButton.set(iconName: "process-stop-symbolic")
        cancelButton.tooltipText = "Cancel"
        cancelButton.valign = .center
        cancelButton.add(cssClass: "flat")
        cancelButton.add(cssClass: "circular")
        cancelButton.onClicked { _ in
            MainActor.assumeIsolated { transfer.cancel() }
        }
        widget.append(child: cancelButton)

        observe()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            _Concurrency.Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        progressBar.fraction = transfer.fractionCompleted ?? 0
        progressLabel.setText(str: transfer.progressDescription)
    }
}

@MainActor
private final class FileDialogRequest {
    enum Choice {
        case saveAs
        case folder
        case files
        case folders
    }

    private let choice: Choice
    private let dialog = FileDialog()
    private let completion: ([String]) -> Void

    static func present(_ choice: Choice, title: String, acceptLabel: String? = nil, initialName: String? = nil, parent: Gtk.Window,
                        completion: @escaping ([String]) -> Void) {
        let request = FileDialogRequest(choice: choice, completion: completion)
        request.dialog.set(title: title)
        request.dialog.set(modal: true)
        if let acceptLabel {
            request.dialog.set(acceptLabel: acceptLabel)
        }
        if let initialName {
            request.dialog.initialName = initialName
        }
        request.start(parent: Gtk.WindowRef(parent))
    }

    private init(choice: Choice, completion: @escaping ([String]) -> Void) {
        self.choice = choice
        self.completion = completion
    }

    private func start(parent: Gtk.WindowRef) {
        let userData = Unmanaged.passRetained(self).toOpaque()
        switch choice {
        case .saveAs:
            dialog.save(parent: parent, callback: fileDialogFinished, userData: userData)
        case .folder:
            dialog.selectFolder(parent: parent, callback: fileDialogFinished, userData: userData)
        case .files:
            dialog.openMultiple(parent: parent, callback: fileDialogFinished, userData: userData)
        case .folders:
            dialog.selectMultipleFolders(parent: parent, callback: fileDialogFinished, userData: userData)
        }
    }

    fileprivate func finish(_ result: GIO.AsyncResultRef) {
        completion(chosenPaths(from: result))
    }

    private func chosenPaths(from result: GIO.AsyncResultRef) -> [String] {
        do {
            switch choice {
            case .saveAs:
                return Self.paths(of: [try dialog.saveFinish(result: result)])
            case .folder:
                return Self.paths(of: [try dialog.selectFolderFinish(result: result)])
            case .files:
                return Self.paths(in: try dialog.openMultipleFinish(result: result))
            case .folders:
                return Self.paths(in: try dialog.selectMultipleFoldersFinish(result: result))
            }
        } catch {
            return []
        }
    }

    private static func paths(in files: GIO.ListModelRef) -> [String] {
        defer { g_object_unref(files.ptr) }
        let items = (0..<files.getNItems()).map { GIO.FileRef(raw: files.getItem(position: $0)!) }
        return paths(of: items)
    }

    private static func paths(of files: [GIO.FileRef]) -> [String] {
        defer { files.forEach { g_object_unref($0.ptr) } }
        return files.compactMap { $0.getPath() }
    }
}

private let fileDialogFinished: GAsyncReadyCallback = { _, result, userData in
    let resultAddress = UInt(bitPattern: result)
    let requestAddress = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let request = Unmanaged<FileDialogRequest>.fromOpaque(UnsafeMutableRawPointer(bitPattern: requestAddress)!).takeRetainedValue()
        request.finish(GIO.AsyncResultRef(raw: UnsafeMutableRawPointer(bitPattern: resultAddress)!))
    }
}

@MainActor
private final class DragDownload: ContentProviderSubclass {
    private let node: LumaCore.ProcessNode
    private let remotePaths: [String]
    private var uriList: _Concurrency.Task<String, Swift.Error>?

    init(node: LumaCore.ProcessNode, remotePaths: [String]) {
        self.node = node
        self.remotePaths = remotePaths
        super.init()
    }

    override func refFormats() -> UnsafeMutablePointer<GdkContentFormats>? {
        gdk_content_formats_parse("text/uri-list")
    }

    override func writeMimeType(mimeType: UnsafePointer<CChar>?, stream: UnsafeMutablePointer<GOutputStream>?, ioPriority: CInt,
                                cancellable: UnsafeMutablePointer<GCancellable>?) async throws {
        var bytes = Array(try await fetchURIList().utf8)
        let output = GIO.OutputStreamRef(raw: stream!)
        try bytes.withUnsafeMutableBytes { buffer in
            _ = try output.writeAll(buffer: buffer.baseAddress, count: buffer.count, cancellable: cancellable.map { GIO.CancellableRef(raw: $0) })
        }
    }

    private func fetchURIList() async throws -> String {
        let task = uriList ?? _Concurrency.Task { try await download() }
        uriList = task
        return try await task.value
    }

    private func download() async throws -> String {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await node.download(remotePaths, into: staging).waitUntilFinished()
        return remotePaths.map { staging.appendingPathComponent(RemotePath.lastComponent(of: $0)).absoluteString + "\r\n" }.joined()
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

    private static func describe(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    fileprivate static func directoriesFirst(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
        if lhs.opensAsDirectory != rhs.opensAsDirectory {
            return lhs.opensAsDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
