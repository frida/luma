import Foundation

@MainActor
public final class EngineRegistry {
    public static let shared = EngineRegistry()

    public init() {}

    private var engines: [URL: Engine] = [:]
    private var startTasks: [URL: Task<Void, Never>] = [:]

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

    public func release(workingProjectURL: URL) async {
        let key = workingProjectURL.standardizedFileURL
        let pending = startTasks.removeValue(forKey: key)
        let engine = engines.removeValue(forKey: key)
        await pending?.value
        await engine?.shutdown()
    }
}
