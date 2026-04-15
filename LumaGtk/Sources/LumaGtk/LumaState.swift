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

    var windowWidth: Int {
        get { stored.windowWidth ?? 1200 }
        set { stored.windowWidth = newValue; persist() }
    }

    var windowHeight: Int {
        get { stored.windowHeight ?? 800 }
        set { stored.windowHeight = newValue; persist() }
    }

    var windowMaximized: Bool {
        get { stored.windowMaximized ?? false }
        set { stored.windowMaximized = newValue; persist() }
    }

    var sidebarSashPosition: Int {
        get { stored.sidebarSashPosition ?? 280 }
        set { stored.sidebarSashPosition = newValue; persist() }
    }

    var collaborationSashPosition: Int {
        get { stored.collaborationSashPosition ?? 880 }
        set { stored.collaborationSashPosition = newValue; persist() }
    }

    var eventStreamSashPosition: Int? {
        get { stored.eventStreamSashPosition }
        set { stored.eventStreamSashPosition = newValue; persist() }
    }

    var eventStreamCollapsed: Bool {
        get { stored.eventStreamCollapsed ?? true }
        set { stored.eventStreamCollapsed = newValue; persist() }
    }

    func saveWindowGeometry(width: Int, height: Int, maximized: Bool) {
        stored.windowWidth = width
        stored.windowHeight = height
        stored.windowMaximized = maximized
        persist()
    }

    func saveSashes(sidebar: Int, collaboration: Int, eventStream: Int? = nil, eventStreamCollapsed: Bool) {
        stored.sidebarSashPosition = sidebar
        stored.collaborationSashPosition = collaboration
        if let eventStream {
            stored.eventStreamSashPosition = eventStream
        }
        stored.eventStreamCollapsed = eventStreamCollapsed
        persist()
    }

    private struct Stored: Codable {
        var lastDocumentPath: String?
        var recentPaths: [String] = []
        var windowWidth: Int?
        var windowHeight: Int?
        var windowMaximized: Bool?
        var sidebarSashPosition: Int?
        var collaborationSashPosition: Int?
        var eventStreamSashPosition: Int?
        var eventStreamCollapsed: Bool?
    }

    private var stored: Stored
    private let stateURL: URL
    private let maxRecents = 10

    private init() {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        let configDir = xdg.appendingPathComponent("luma", isDirectory: true)
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
