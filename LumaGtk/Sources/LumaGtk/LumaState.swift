import Foundation

@MainActor
final class LumaState {
    static let shared = LumaState()

    var lastDocumentPath: String? {
        get { stored.lastDocumentPath }
        set {
            stored.lastDocumentPath = newValue
            persist()
        }
    }

    var recentPaths: [String] {
        stored.recentPaths
    }

    func recordRecent(path: String) {
        var list = stored.recentPaths.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > maxRecents {
            list = Array(list.prefix(maxRecents))
        }
        stored.recentPaths = list
        persist()
    }

    private struct Stored: Codable {
        var lastDocumentPath: String?
        var recentPaths: [String] = []
    }

    private var stored: Stored
    private let stateURL: URL
    private let maxRecents = 10

    private init() {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        let configDir = xdg.appendingPathComponent("re.frida.Luma", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.stateURL = configDir.appendingPathComponent("state.json")

        if let data = try? Data(contentsOf: stateURL),
            let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        {
            self.stored = decoded
        } else {
            self.stored = Stored()
        }

        let pruned = stored.recentPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if pruned.count != stored.recentPaths.count {
            stored.recentPaths = pruned
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
