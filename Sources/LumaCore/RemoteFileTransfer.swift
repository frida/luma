import Foundation
import Observation

@Observable
@MainActor
public final class RemoteFileTransfer: Identifiable {
    public enum Direction: Sendable {
        case upload
        case download
    }

    public enum Phase: Sendable {
        case preparing
        case transferring
    }

    public let id = UUID()
    public let direction: Direction
    public let itemNames: [String]
    public private(set) var phase: Phase = .preparing
    public private(set) var totalBytes: Int64 = 0
    public private(set) var transferredBytes: Int64 = 0
    public private(set) var currentItemName: String?

    @ObservationIgnored public let progress = Progress(totalUnitCount: -1)
    @ObservationIgnored private var task: Task<Void, Swift.Error>!

    init(direction: Direction, itemNames: [String]) {
        self.direction = direction
        self.itemNames = itemNames
        progress.kind = .file
        #if canImport(Darwin)
            progress.fileOperationKind = direction == .upload ? .uploading : .downloading
        #endif
        progress.cancellationHandler = { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    public var subject: String {
        itemNames.count == 1 ? itemNames[0] : "\(itemNames.count) items"
    }

    public var activityDescription: String {
        switch direction {
        case .upload:
            return "Uploading \(subject)"
        case .download:
            return "Downloading \(subject)"
        }
    }

    public var progressDescription: String {
        switch phase {
        case .preparing:
            return "Preparing…"
        case .transferring:
            let transferred = ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return [currentItemName, "\(transferred) of \(total)"].compactMap { $0 }.joined(separator: " — ")
        }
    }

    public var fractionCompleted: Double? {
        guard case .transferring = phase, totalBytes > 0 else { return nil }
        return Double(transferredBytes) / Double(totalBytes)
    }

    public func cancel() {
        task.cancel()
    }

    public func waitUntilFinished() async throws {
        try await task.value
    }

    func start(_ body: @escaping @MainActor (RemoteFileTransfer) async throws -> Void) {
        task = Task { @MainActor in
            try await body(self)
            try Task.checkCancellation()
        }
    }

    func beginTransferring(totalBytes: Int64) {
        self.totalBytes = totalBytes
        phase = .transferring
        progress.totalUnitCount = totalBytes
    }

    func beginItem(named name: String) {
        currentItemName = name
    }

    func advance(by count: Int64) {
        transferredBytes += count
        progress.completedUnitCount = transferredBytes
    }
}

struct RemoteTreeEntry {
    let path: String
    let components: [String]
    let kind: Kind
    let size: Int64

    enum Kind: String {
        case file
        case directory
    }

    static func fromJSON(_ dict: [String: Any]) -> RemoteTreeEntry? {
        guard let path = dict["path"] as? String,
            let components = dict["components"] as? [String],
            let kind = (dict["kind"] as? String).flatMap(Kind.init(rawValue:)),
            let size = dict["size"] as? NSNumber
        else {
            return nil
        }
        return RemoteTreeEntry(path: path, components: components, kind: kind, size: size.int64Value)
    }
}

struct LocalTreeEntry {
    let url: URL
    let components: [String]
    let kind: Kind
    let size: Int64

    enum Kind {
        case file
        case directory
    }

    static func walk(_ root: URL) throws -> [LocalTreeEntry] {
        guard let rootEntry = try entry(at: root, components: [root.lastPathComponent]) else {
            throw LumaCoreError.notSupported("\(root.lastPathComponent) is neither a file nor a directory")
        }
        guard rootEntry.kind == .directory else { return [rootEntry] }
        var entries = [rootEntry]
        try walkDirectory(root, components: rootEntry.components, into: &entries)
        return entries
    }

    private static func walkDirectory(_ directory: URL, components: [String], into entries: inout [LocalTreeEntry]) throws {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(resourceKeys))
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let childComponents = components + [child.lastPathComponent]
            let isSymlink = try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            guard let entry = try entry(at: child, components: childComponents), !(isSymlink && entry.kind == .directory) else {
                continue
            }
            entries.append(entry)
            if entry.kind == .directory {
                try walkDirectory(child, components: childComponents, into: &entries)
            }
        }
    }

    private static func entry(at url: URL, components: [String]) throws -> LocalTreeEntry? {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: resourceKeys)
        if values.isDirectory == true {
            return LocalTreeEntry(url: url, components: components, kind: .directory, size: 0)
        }
        if values.isRegularFile == true {
            return LocalTreeEntry(url: url, components: components, kind: .file, size: Int64(values.fileSize ?? 0))
        }
        return nil
    }

    private static let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
}
