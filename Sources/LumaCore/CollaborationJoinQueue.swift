import Foundation

public final class CollaborationJoinQueue: @unchecked Sendable {
    public static let shared = CollaborationJoinQueue()

    private let lock = NSLock()
    private var pending: [String] = []

    public func enqueue(roomID: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(roomID)
    }

    public func consumeNext() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
