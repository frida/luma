import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    let sessionID: UUID
    let engine: Engine

    @State private var path = ""
    @State private var pathDraft = ""
    @State private var roots: RemoteFilesystemRoots?
    @State private var entries: [RemoteFileEntry] = []
    @State private var selectedNames: Set<String> = []
    @State private var isLoading = false
    @State private var problem: String?
    @State private var isChoosingUploads = false
    @State private var isDropTargeted = false
    @State private var pendingDeletion: [RemoteFileEntry] = []
    #if !os(macOS)
        @State private var downloaded: [URL] = []
    #endif

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: sessionID)
    }

    private var attachedNodeID: UUID? {
        guard engine.session(id: sessionID)?.phase == .attached else { return nil }
        return node?.id
    }

    private var acceptsUploads: Bool {
        node != nil && !path.isEmpty
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1 ? "Delete “\(pendingDeletion[0].name)”?" : "Delete \(pendingDeletion.count) items?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            table
            if let transfers = node?.fileTransfers, !transfers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(transfers) { transfer in
                        FileTransferRow(transfer: transfer)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: attachedNodeID) {
            await start()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete(pendingDeletion) }
        } message: {
            Text("This can’t be undone.")
        }
        .fileImporter(isPresented: $isChoosingUploads, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if let urls = try? result.get() {
                upload(urls)
            }
        }
        #if !os(macOS)
            .fileMover(
                isPresented: Binding(
                    get: { !downloaded.isEmpty },
                    set: { if !$0 { downloaded = [] } }
                ),
                files: downloaded
            ) { _ in }
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                if let roots {
                    Button("Root") { navigate(to: roots.root) }
                    if let home = roots.home {
                        Button("Home") { navigate(to: home) }
                    }
                    if let current = roots.currentDirectory {
                        Button("Current Directory") { navigate(to: current) }
                    }
                    if let temporary = roots.temporaryDirectory {
                        Button("Temporary Directory") { navigate(to: temporary) }
                    }
                }
            } label: {
                Label("Go", systemImage: "folder")
            }
            .fixedSize()
            Button {
                navigate(to: RemotePath.parent(of: path))
            } label: {
                Label("Up", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(RemotePath.parent(of: path) == path)
            TextField("Path", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { navigate(to: pathDraft) }
            Button {
                navigate(to: path)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .disabled(isLoading)
            Button("Upload…") {
                isChoosingUploads = true
            }
            .disabled(!acceptsUploads)
        }
    }

    private var table: some View {
        Table(of: RemoteFileEntry.self, selection: $selectedNames) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(entry.name)
                    if let target = entry.target {
                        Text("→ \(target.path)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Size") { entry in
                Text(entry.kind == .file ? ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file) : "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified") { entry in
                Text(entry.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Permissions") { entry in
                Text(entry.permissions)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Owner") { entry in
                Text("\(entry.owner):\(entry.group)")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            ForEach(entries) { entry in
                TableRow(entry)
                    .itemProvider { dragProvider(for: entry) }
            }
        }
        .contextMenu(forSelectionType: String.self) { names in
            let selected = entries.filter { names.contains($0.name) }
            if selected.count == 1, selected[0].opensAsDirectory {
                Button("Open") { open(selected[0]) }
            }
            if !selected.isEmpty, selected.allSatisfy(\.isDownloadable) {
                Button("Download…") { download(selected) }
            }
            if selected.count == 1 {
                Button("Copy Path") { copyPath(of: selected[0]) }
            }
            if !selected.isEmpty {
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = selected }
            }
        } primaryAction: { names in
            if let entry = names.first.flatMap(entry(named:)) {
                open(entry)
            }
        }
        #if os(macOS)
            .onDeleteCommand {
                pendingDeletion = entries.filter { selectedNames.contains($0.name) }
            }
        #endif
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsUploads else { return false }
            upload(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && acceptsUploads
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            } else if isLoading && entries.isEmpty {
                ProgressView()
            }
        }
    }

    private var dropHighlight: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.1))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc")
                    .font(.largeTitle)
                Text("Upload to \(path)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.accentColor)
            .padding()
        }
        .allowsHitTesting(false)
    }

    private func start() async {
        guard let node else { return }
        do {
            let roots = try await node.filesystemRoots()
            self.roots = roots
            navigate(to: path.isEmpty ? roots.currentDirectory ?? roots.root : path)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func navigate(to target: String) {
        guard let node else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let listing = try await node.listDirectory(at: target)
                path = listing.path
                pathDraft = listing.path
                entries = listing.entries.sorted(by: RemoteFileEntry.directoriesFirst)
                selectedNames = []
                problem = nil
            } catch {
                problem = "\(target): \(error.localizedDescription)"
            }
        }
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.opensAsDirectory {
            navigate(to: RemotePath.join(path, entry.name))
        } else {
            download([entry])
        }
    }

    private func download(_ selected: [RemoteFileEntry]) {
        guard let node else { return }
        let remotePaths = selected.map { RemotePath.join(path, $0.name) }
        #if os(macOS)
            if selected.count == 1 {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = selected[0].name
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                watch(node.download(remotePaths[0], to: destination))
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Download"
                guard panel.runModal() == .OK, let directory = panel.url else { return }
                watch(node.download(remotePaths, into: directory))
            }
        #else
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let transfer = node.download(remotePaths, into: staging)
            watch(transfer) {
                downloaded = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            }
        #endif
    }

    private func upload(_ sources: [URL]) {
        guard let node else { return }
        let accessed = sources.filter { $0.startAccessingSecurityScopedResource() }
        watch(node.upload(sources, into: path)) {
            for source in accessed {
                source.stopAccessingSecurityScopedResource()
            }
            navigate(to: path)
        }
    }

    private func watch(_ transfer: RemoteFileTransfer, then finish: @escaping () -> Void = {}) {
        Task {
            do {
                try await transfer.waitUntilFinished()
            } catch {
                if !(error is CancellationError) {
                    problem = "\(transfer.subject): \(error.localizedDescription)"
                }
            }
            finish()
        }
    }

    private func delete(_ doomed: [RemoteFileEntry]) {
        guard let node else { return }
        let remotePaths = doomed.map { RemotePath.join(path, $0.name) }
        Task {
            do {
                try await node.removeItems(at: remotePaths)
            } catch {
                problem = error.localizedDescription
            }
            navigate(to: path)
        }
    }

    private func dragProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        guard let node, entry.isDownloadable else { return provider }
        let remotePath = RemotePath.join(path, entry.name)
        provider.registerFileRepresentation(forTypeIdentifier: entry.contentType.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let destination = staging.appendingPathComponent(entry.name)
                    let transfer = node.download(remotePath, to: destination)
                    progress.addChild(transfer.progress, withPendingUnitCount: 1)
                    try await transfer.waitUntilFinished()
                    completion(destination, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                try? FileManager.default.removeItem(at: staging)
            }
            return progress
        }
        return provider
    }

    private func copyPath(of entry: RemoteFileEntry) {
        let remotePath = RemotePath.join(path, entry.name)
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(remotePath, forType: .string)
        #else
            UIPasteboard.general.string = remotePath
        #endif
    }

    private func entry(named name: String) -> RemoteFileEntry? {
        entries.first { $0.name == name }
    }
}

private struct FileTransferRow: View {
    let transfer: RemoteFileTransfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.activityDescription)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = transfer.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(transfer.progressDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button {
                transfer.cancel()
            } label: {
                Label("Cancel", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
    }
}

extension RemoteFileEntry {
    fileprivate var contentType: UTType {
        opensAsDirectory ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    fileprivate var symbolName: String {
        switch target?.kind ?? kind {
        case .directory:
            return "folder"
        case .file:
            return "doc"
        case .symlink:
            return "link"
        case .characterDevice, .blockDevice:
            return "externaldrive"
        case .fifo:
            return "arrow.left.arrow.right"
        case .socket:
            return "network"
        }
    }

    fileprivate static func directoriesFirst(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
        if lhs.opensAsDirectory != rhs.opensAsDirectory {
            return lhs.opensAsDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
