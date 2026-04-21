import Foundation

public struct LumaAppPaths: Sendable {
    public let stateURL: URL
    public let untitledDirectory: URL
    public let dataDirectory: URL

    public init(stateURL: URL, untitledDirectory: URL, dataDirectory: URL) {
        self.stateURL = stateURL
        self.untitledDirectory = untitledDirectory
        self.dataDirectory = dataDirectory
    }

    public static let shared: LumaAppPaths = makeDefault()

    private static func makeDefault() -> LumaAppPaths {
        let fm = FileManager.default
        #if os(macOS) || os(iOS) || os(visionOS)
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "re.frida.Luma"
        let root = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let untitled = root.appendingPathComponent("Untitled", isDirectory: true)
        try? fm.createDirectory(at: untitled, withIntermediateDirectories: true)
        return LumaAppPaths(
            stateURL: root.appendingPathComponent("state.json"),
            untitledDirectory: untitled,
            dataDirectory: root
        )
        #else
        let env = ProcessInfo.processInfo.environment
        let xdgConfigHome = env["XDG_CONFIG_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        let xdgDataHome = env["XDG_DATA_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        let configDir = xdgConfigHome.appendingPathComponent("luma", isDirectory: true)
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let dataDir = xdgDataHome.appendingPathComponent("luma", isDirectory: true)
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let untitled = dataDir.appendingPathComponent("Untitled", isDirectory: true)
        try? fm.createDirectory(at: untitled, withIntermediateDirectories: true)
        return LumaAppPaths(
            stateURL: configDir.appendingPathComponent("state.json"),
            untitledDirectory: untitled,
            dataDirectory: dataDir
        )
        #endif
    }
}
