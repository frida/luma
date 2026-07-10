public struct ModuleDelta: Sendable {
    public let added: [ProcessModule]
    public let removed: [ProcessModule]

    public init(added: [ProcessModule] = [], removed: [ProcessModule] = []) {
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    public func applied(to base: [ProcessModule]?) -> [ProcessModule] {
        var result = base ?? []
        if !removed.isEmpty {
            let removedBases = Set(removed.map { $0.base })
            result.removeAll { removedBases.contains($0.base) }
        }
        result.append(contentsOf: added)
        return result
    }
}

public enum ModuleAnalysisStatus: Sendable, Hashable {
    case notAnalyzed
    case analyzing
    case analyzed
}

extension Sequence where Element == ProcessModule {
    public func sortedByOrigin() -> [ProcessModule] {
        sorted { lhs, rhs in
            if lhs.isSystemModule != rhs.isSystemModule { return !lhs.isSystemModule }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

extension Array where Element == ProcessModule {
    public func sidebarHighlights(
        mainModule: ProcessModule?,
        selectedID: ProcessModule.ID?,
        limit: Int = SidebarHighlights.defaultLimit
    ) -> [ProcessModule] {
        let main = mainModule.flatMap { wanted in first { $0.id == wanted.id } } ?? first
        let peers = filter { $0.id != main?.id && $0.isSystemModule == (main?.isSystemModule ?? false) }
            .prefix(Swift.max(0, limit - 1))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let featured = ([main].compactMap { $0 } + peers)
        return featured.withSelected(selectedID, from: self, limit: limit)
    }
}

public struct ProcessModule: Hashable, Identifiable, Codable, Sendable {
    public var id: String { "\(path)@0x\(String(base, radix: 16))" }
    public let name: String
    public let path: String
    public let base: UInt64
    public let size: UInt64

    public init(name: String, path: String, base: UInt64, size: UInt64) {
        self.name = name
        self.path = path
        self.base = base
        self.size = size
    }

    private static let rerootedSystemMarkers = ["/usr/lib/", "/usr/local/lib/", "/usr/libexec/"]
    private static let systemPathPrefixes = [
        "/usr/", "/lib/", "/lib64/", "/opt/", "/System/", "/Library/",
        "/system/", "/apex/", "/vendor/", "/product/", "/system_ext/",
    ]

    public var isSystemModule: Bool {
        let windows = path.lowercased()
        if windows.contains(":\\windows\\") || windows.hasPrefix("\\windows\\") {
            return true
        }
        if Self.rerootedSystemMarkers.contains(where: path.contains) {
            return true
        }
        return Self.systemPathPrefixes.contains(where: path.hasPrefix)
    }

    public func toJSON() -> [String: Any] {
        return [
            "name": name,
            "path": path,
            "base": String(format: "0x%llx", base),
            "size": Int(size),
        ]
    }

    public static func fromJSON(_ obj: [String: Any]) -> ProcessModule? {
        guard let name = obj["name"] as? String,
            let path = obj["path"] as? String,
            let baseStr = obj["base"] as? String,
            let size = obj["size"] as? Int
        else { return nil }

        let base = UInt64(baseStr.dropFirst(2), radix: 16) ?? 0
        return ProcessModule(name: name, path: path, base: base, size: UInt64(size))
    }
}
