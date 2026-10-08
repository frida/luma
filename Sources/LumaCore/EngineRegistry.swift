import Foundation

@MainActor
public final class EngineRegistry {
    public static let shared = EngineRegistry()

    public init() {}

    private var engines: [URL: Engine] = [:]
    private var startTasks: [URL: Task<Void, Never>] = [:]
    private var shutdownTasks: [URL: Task<Void, Never>] = [:]

    public func engine(
        for workingProjectURL: URL,
        dataDirectory: URL,
        gitHubAuth: GitHubAuth? = nil
    ) throws -> Engine {
        let key = workingProjectURL.standardizedFileURL
        if let existing = engines[key] {
            return existing
        }
        let fm = FileManager.default
        let dbURL = key.appendingPathComponent("db.sqlite")
        let tracesURL = key.appendingPathComponent("traces", isDirectory: true)
        let eventsURL = key.appendingPathComponent("events.log")
        try fm.createDirectory(at: key, withIntermediateDirectories: true)
        try fm.createDirectory(at: tracesURL, withIntermediateDirectories: true)
        let store = try ProjectStore(path: dbURL.path)
        let blobs = try BlobStore(directory: tracesURL)
        let eventStore = EventStore(fileURL: eventsURL)
        let engine = Engine(
            store: store,
            blobs: blobs,
            eventStore: eventStore,
            dataDirectory: dataDirectory,
            gitHubAuth: gitHubAuth
        )
        engines[key] = engine
        return engine
    }

    public func startIfNeeded(for workingProjectURL: URL) async {
        let key = workingProjectURL.standardizedFileURL
        if let existing = startTasks[key] {
            await existing.value
            return
        }
        guard let engine = engines[key] else { return }
        let task = Task { @MainActor in
            await engine.start()
        }
        startTasks[key] = task
        await task.value
    }

    public func shutdownAll() async {
        for key in Array(engines.keys) {
            _ = shutdownTask(for: key)
        }
        for task in Array(shutdownTasks.values) {
            await task.value
        }
    }

    public func release(workingProjectURL: URL) async {
        await shutdownTask(for: workingProjectURL.standardizedFileURL).value
    }

    private func shutdownTask(for key: URL) -> Task<Void, Never> {
        if let existing = shutdownTasks[key] {
            return existing
        }
        let pending = startTasks.removeValue(forKey: key)
        let engine = engines.removeValue(forKey: key)
        let task = Task { @MainActor in
            await pending?.value
            await engine?.shutdown()
            self.shutdownTasks.removeValue(forKey: key)
        }
        shutdownTasks[key] = task
        return task
    }
}
