import Foundation

/// What the image is allowed to ask the host about. The image resolves these
/// by name through dlsym and calls them from its own thread, so what they read
/// is a snapshot the host publishes rather than anything it owns.
public final class PharoHostBridge: @unchecked Sendable {
    public static let shared = PharoHostBridge()

    private let lock = NSLock()
    private var sessions: Int32 = 0
    private var notebookEntries: Int32 = 0

    public func publish(sessions: Int, notebookEntries: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.sessions = Int32(sessions)
        self.notebookEntries = Int32(notebookEntries)
    }

    fileprivate var currentSessions: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    fileprivate var currentNotebookEntries: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return notebookEntries
    }
}

@_cdecl("luma_session_count")
public func luma_session_count() -> Int32 {
    PharoHostBridge.shared.currentSessions
}

@_cdecl("luma_notebook_entry_count")
public func luma_notebook_entry_count() -> Int32 {
    PharoHostBridge.shared.currentNotebookEntries
}
