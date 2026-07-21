import Foundation

/// What the image is allowed to ask the host about. The image resolves these
/// by name through dlsym and calls them from its own thread, so what they read
/// is a snapshot the host publishes rather than anything it owns.
/// The runs of lines the image can ask the host for, each fetched on its own.
public enum PharoHostFeed: String, Sendable, CaseIterable {
    case sessions
    case notebookEntries
    case events
}

public final class PharoHostBridge: @unchecked Sendable {
    public static let shared = PharoHostBridge()

    private let lock = NSLock()
    /// Owned here and handed to the image as plain pointers. The host only
    /// replaces one between requests, while the image sits idle waiting.
    private var feeds: [PharoHostFeed: UnsafeMutablePointer<CChar>] = [:]

    public func publish(_ lines: [String], as feed: PharoHostFeed) {
        lock.lock()
        defer { lock.unlock() }
        free(feeds[feed])
        feeds[feed] = strdup(lines.joined(separator: "\n"))
    }

    fileprivate func lines(of feed: PharoHostFeed) -> UnsafeMutablePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        return feeds[feed]
    }
}

@_cdecl("luma_sessions")
public func luma_sessions() -> UnsafeMutablePointer<CChar>? {
    PharoHostBridge.shared.lines(of: .sessions)
}

@_cdecl("luma_notebook_entries")
public func luma_notebook_entries() -> UnsafeMutablePointer<CChar>? {
    PharoHostBridge.shared.lines(of: .notebookEntries)
}

@_cdecl("luma_events")
public func luma_events() -> UnsafeMutablePointer<CChar>? {
    PharoHostBridge.shared.lines(of: .events)
}
