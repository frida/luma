import Foundation

@MainActor
public final class LumaAppState {
    public static let shared: LumaAppState = LumaAppState(paths: .shared)

    private struct Stored: Codable, Equatable {
        var untitledRelative: String?
        var externalAbsolute: String?
        var recentPaths: [String] = []
    }

    private var stored: Stored
    private let paths: LumaAppPaths
    private let maxRecents = 10

    public init(paths: LumaAppPaths) {
        self.paths = paths

        let fm = FileManager.default
        if fm.fileExists(atPath: paths.stateURL.path),
           let data = try? Data(contentsOf: paths.stateURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        {
            self.stored = decoded
        } else {
            self.stored = Stored()
        }
    }

    public var untitledDirectory: URL { paths.untitledDirectory }
    public var dataDirectory: URL { paths.dataDirectory }

    public var lastDocumentPath: String? {
        get {
            if let rel = stored.untitledRelative {
                return paths.untitledDirectory.appendingPathComponent(rel).path
            }
            return stored.externalAbsolute
        }
        set {
            var next = stored
            if let newValue {
                let prefix = paths.untitledDirectory.path + "/"
                if newValue.hasPrefix(prefix) {
                    next.untitledRelative = String(newValue.dropFirst(prefix.count))
                    next.externalAbsolute = nil
                } else {
                    next.untitledRelative = nil
                    next.externalAbsolute = newValue
                }
            } else {
                next.untitledRelative = nil
                next.externalAbsolute = nil
            }
            guard stored != next else { return }
            stored = next
            persist()
        }
    }

    public var recentPaths: [String] {
        stored.recentPaths
    }

    public func recordRecent(path: String) {
        var list = stored.recentPaths.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > maxRecents {
            list = Array(list.prefix(maxRecents))
        }
        guard list != stored.recentPaths else { return }
        stored.recentPaths = list
        persist()
    }

    public func pruneMissingRecents() {
        let fm = FileManager.default
        let pruned = stored.recentPaths.filter { fm.fileExists(atPath: $0) }
        guard pruned.count != stored.recentPaths.count else { return }
        stored.recentPaths = pruned
        persist()
    }

    public func isUntitledAutoSavePath(_ path: String) -> Bool {
        path.hasPrefix(paths.untitledDirectory.path + "/") || path == paths.untitledDirectory.path
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: paths.stateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("[LumaAppState] persist failed at \(paths.stateURL.path): \(error)\n".utf8)
            )
        }
    }
}
