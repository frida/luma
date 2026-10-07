import Foundation

public struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    public var id: String { name }

    public let name: String
    public let kind: Kind
    public let target: LinkTarget?
    public let size: UInt64
    public let modifiedAt: Date
    public let permissions: String
    public let owner: String
    public let group: String

    public enum Kind: String, Sendable {
        case file
        case directory
        case symlink
        case characterDevice = "character-device"
        case blockDevice = "block-device"
        case fifo
        case socket
    }

    public struct LinkTarget: Hashable, Sendable {
        public let path: String
        public let kind: Kind?
    }

    public var opensAsDirectory: Bool {
        kind == .directory || target?.kind == .directory
    }

    static func fromJSON(_ dict: [String: Any]) -> RemoteFileEntry? {
        guard let name = dict["name"] as? String,
            let kind = (dict["kind"] as? String).flatMap(Kind.init(rawValue:)),
            let size = dict["size"] as? NSNumber,
            let mtime = dict["mtime"] as? NSNumber,
            let permissions = dict["permissions"] as? String,
            let owner = dict["owner"] as? String,
            let group = dict["group"] as? String
        else {
            return nil
        }
        let target = (dict["target"] as? [String: Any]).flatMap { target -> LinkTarget? in
            guard let path = target["path"] as? String else { return nil }
            return LinkTarget(path: path, kind: (target["kind"] as? String).flatMap(Kind.init(rawValue:)))
        }
        return RemoteFileEntry(
            name: name, kind: kind, target: target, size: size.uint64Value, modifiedAt: Date(timeIntervalSince1970: mtime.doubleValue / 1000),
            permissions: permissions, owner: owner, group: group)
    }
}

public struct RemoteDirectoryListing: Sendable {
    public let path: String
    public let entries: [RemoteFileEntry]

    static func fromJSON(_ dict: [String: Any]) -> RemoteDirectoryListing? {
        guard let path = dict["path"] as? String, let entries = dict["entries"] as? [[String: Any]] else { return nil }
        return RemoteDirectoryListing(path: path, entries: entries.compactMap(RemoteFileEntry.fromJSON))
    }
}

public struct RemoteFilesystemRoots: Sendable {
    public let root: String
    public let home: String?
    public let currentDirectory: String?
    public let temporaryDirectory: String?

    static func fromJSON(_ dict: [String: Any]) -> RemoteFilesystemRoots? {
        guard let root = dict["root"] as? String else { return nil }
        return RemoteFilesystemRoots(
            root: root, home: dict["home"] as? String, currentDirectory: dict["cwd"] as? String, temporaryDirectory: dict["tmp"] as? String)
    }
}

public enum RemotePath {
    public static func join(_ directory: String, _ name: String) -> String {
        let separator = separator(in: directory)
        return directory.hasSuffix(separator) ? directory + name : directory + separator + name
    }

    public static func parent(of path: String) -> String {
        let separator = separator(in: path)
        let trimmed = path.count > 1 && path.hasSuffix(separator) ? String(path.dropLast()) : path
        guard let cut = trimmed.lastIndex(where: { String($0) == separator }) else { return path }
        let parent = String(trimmed[..<cut])
        return parent.isEmpty || parent.hasSuffix(":") ? parent + separator : parent
    }

    private static func separator(in path: String) -> String {
        path.contains("\\") && !path.contains("/") ? "\\" : "/"
    }
}
