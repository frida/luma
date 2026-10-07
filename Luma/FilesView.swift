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
    @State private var transfer: String?
    @State private var isImportingPush = false
    @State private var pulled: PulledFile?

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: sessionID)
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
            if let transfer {
                Text(transfer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: node?.id) {
            await start()
        }
        .fileImporter(isPresented: $isImportingPush, allowedContentTypes: [.item]) { result in
            if let url = try? result.get() {
                push(url)
            }
        }
        #if !os(macOS)
            .fileExporter(item: pulled, contentTypes: [.data], defaultFilename: pulled?.name) { _ in
                pulled = nil
            }
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
            Button("Push File Here…") {
                isImportingPush = true
            }
            .disabled(node == nil || path.isEmpty)
        }
    }

    private var table: some View {
        Table(entries, selection: $selectedNames) {
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
        }
        .contextMenu(forSelectionType: String.self) { names in
            if let entry = names.first.flatMap(entry(named:)) {
                if entry.opensAsDirectory {
                    Button("Open") { open(entry) }
                }
                if entry.kind == .file || entry.target?.kind == .file {
                    Button("Pull…") { pull(entry) }
                }
                Button("Copy Path") { copyPath(of: entry) }
            }
        } primaryAction: { names in
            if let entry = names.first.flatMap(entry(named:)) {
                open(entry)
            }
        }
        .overlay {
            if isLoading && entries.isEmpty {
                ProgressView()
            }
        }
    }

    private func entry(named name: String) -> RemoteFileEntry? {
        entries.first { $0.name == name }
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
            pull(entry)
        }
    }

    private func pull(_ entry: RemoteFileEntry) {
        guard let node else { return }
        let remotePath = RemotePath.join(path, entry.name)
        Task {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            var received: Int64 = 0
            transfer = "Pulling \(entry.name)…"
            do {
                try await node.pullFile(at: remotePath, to: temporary) { count in
                    received += count
                    transfer = "Pulling \(entry.name)… \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))"
                }
                transfer = nil
                deliver(PulledFile(name: entry.name, url: temporary))
            } catch {
                transfer = nil
                problem = "\(entry.name): \(error.localizedDescription)"
            }
        }
    }

    private func deliver(_ file: PulledFile) {
        #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file.url, to: destination)
            } catch {
                problem = "\(file.name): \(error.localizedDescription)"
            }
        #else
            pulled = file
        #endif
    }

    private func push(_ source: URL) {
        guard let node else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        let remotePath = RemotePath.join(path, source.lastPathComponent)
        Task {
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }
            var sent: Int64 = 0
            transfer = "Pushing \(source.lastPathComponent)…"
            do {
                try await node.pushFile(from: source, to: remotePath) { count in
                    sent += count
                    transfer = "Pushing \(source.lastPathComponent)… \(ByteCountFormatter.string(fromByteCount: sent, countStyle: .file))"
                }
                transfer = nil
                navigate(to: path)
            } catch {
                transfer = nil
                problem = "\(source.lastPathComponent): \(error.localizedDescription)"
            }
        }
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
}

private struct PulledFile: Transferable {
    let name: String
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(file.url)
        }
    }
}

extension RemoteFileEntry {
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
