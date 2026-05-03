import Foundation

struct TestUser: Sendable {
    let label: String
    let home: URL
    let token: String

    init(label: String, token: String) throws {
        self.label = label
        self.token = token
        self.home = try Self.makeIsolatedHome(label: label)
        try seedGitHubToken()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }

    func launchEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("DYLD_") {
            env.removeValue(forKey: key)
        }
        env["HOME"] = home.path
        env["CFFIXED_USER_HOME"] = home.path
        env["TMPDIR"] = home.appendingPathComponent("tmp").path
        env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        env["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share").path
        try? FileManager.default.createDirectory(
            atPath: home.appendingPathComponent("tmp").path,
            withIntermediateDirectories: true
        )
        for (k, v) in extra {
            env[k] = v
        }
        return env
    }

    private func seedGitHubToken() throws {
        for dir in candidateTokenDirectories() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("re.frida.Luma.github.token")
            try? Data(token.utf8).write(to: url, options: .atomic)
        }
    }

    private func candidateTokenDirectories() -> [URL] {
        let plain = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("re.frida.Luma", isDirectory: true)
            .appendingPathComponent("tokens", isDirectory: true)
        let sandboxed = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("re.frida.Luma", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("re.frida.Luma", isDirectory: true)
            .appendingPathComponent("tokens", isDirectory: true)
        return [plain, sandboxed]
    }

    private static func makeIsolatedHome(label: String) throws -> URL {
        let runID = UUID().uuidString.prefix(8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-test", isDirectory: true)
            .appendingPathComponent("\(runID)-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
