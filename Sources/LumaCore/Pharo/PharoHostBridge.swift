import Foundation

/// What the image is allowed to ask the host about. The image resolves these
/// by name through dlsym and calls them from its own thread, so what they read
/// is a snapshot the host publishes rather than anything it owns.
public final class PharoHostBridge: @unchecked Sendable {
    public static let shared = PharoHostBridge()

    private let lock = NSLock()
    private var sessions: Int32 = 0
    private var notebookEntries: Int32 = 0
    /// Owned here and handed to the image as a plain pointer. The host only
    /// replaces it between requests, while the image sits idle waiting for one.
    private var eventLines: UnsafeMutablePointer<CChar>?

    public func publish(sessions: Int, notebookEntries: Int, events: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.sessions = Int32(sessions)
        self.notebookEntries = Int32(notebookEntries)
        free(eventLines)
        eventLines = strdup(events.joined(separator: "\n"))
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

    fileprivate var currentEventLines: UnsafeMutablePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        return eventLines
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

@_cdecl("luma_event_lines")
public func luma_event_lines() -> UnsafeMutablePointer<CChar>? {
    PharoHostBridge.shared.currentEventLines
}
