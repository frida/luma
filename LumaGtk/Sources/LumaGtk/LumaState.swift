import Foundation
import LumaCore

@MainActor
final class LumaState {
    static let shared = LumaState()

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

    func saveSashes(collaboration: Int, eventStream: Int? = nil, eventStreamCollapsed: Bool) {
        stored.collaborationSashPosition = collaboration
        if let eventStream {
            stored.eventStreamSashPosition = eventStream
        }
        stored.eventStreamCollapsed = eventStreamCollapsed
        persist()
    }

    private struct Stored: Codable {
        var windowWidth: Int?
        var windowHeight: Int?
        var windowMaximized: Bool?
        var collaborationSashPosition: Int?
        var eventStreamSashPosition: Int?
        var eventStreamCollapsed: Bool?
    }

    private var stored: Stored
    private let stateURL: URL

    private init() {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        let configDir = xdg.appendingPathComponent("luma", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.stateURL = configDir.appendingPathComponent("ui-state.json")

        if let data = try? Data(contentsOf: stateURL),
            let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        {
            self.stored = decoded
        } else {
            self.stored = Stored()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
