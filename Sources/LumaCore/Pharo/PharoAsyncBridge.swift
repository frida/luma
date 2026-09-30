import Foundation

public final class PharoAsyncBridge: @unchecked Sendable {
    public static let shared = PharoAsyncBridge()

    public typealias Handler = @MainActor (_ request: [String: Any]) async throws -> Any

    private let lock = NSLock()
    private var handler: Handler?
    private var nextTicket: Int32 = 1
    private var pending: Set<Int32> = []
    private var abandoned: Set<Int32> = []
    private var replies: [Int32: Reply] = [:]

    private static let signalSemaphore = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_NOW), "signalSemaphoreWithIndex"),
        to: (@convention(c) (Int) -> Int).self)

    public func serve(with handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    fileprivate func start(_ requestJSON: String, semaphore: Int) -> Int32 {
        lock.lock()
        let ticket = nextTicket
        nextTicket += 1
        pending.insert(ticket)
        let handler = handler
        lock.unlock()

        Task { @MainActor in
            let reply = await Self.reply(to: requestJSON, using: handler)
            self.deliver(reply, for: ticket, signalling: semaphore)
        }
        return ticket
    }

    fileprivate func take(_ ticket: Int32) -> UnsafeMutablePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        pending.remove(ticket)
        return strdup(replies.removeValue(forKey: ticket)?.json ?? #"{"error":"no reply for this ticket"}"#)
    }

    fileprivate func abandon(_ ticket: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if let reply = replies.removeValue(forKey: ticket) {
            pending.remove(ticket)
            reply.discard()
        } else if pending.contains(ticket) {
            abandoned.insert(ticket)
        }
    }

    @MainActor
    private static func reply(to requestJSON: String, using handler: Handler?) async -> Reply {
        let envelope: [String: Any]
        var discard: @Sendable () -> Void = {}
        do {
            guard let handler else { throw PharoAsyncBridgeError.notServing }
            guard let request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any] else {
                throw PharoAsyncBridgeError.malformedRequest
            }
            let result = try await handler(request)
            if let held = result as? PharoHeldResult {
                envelope = ["result": held.value]
                discard = held.release
            } else {
                envelope = ["result": result]
            }
        } catch {
            envelope = ["error": error.localizedDescription]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.fragmentsAllowed]) else {
            discard()
            return Reply(json: #"{"error":"the reply could not be encoded"}"#, discard: {})
        }
        return Reply(json: String(decoding: data, as: UTF8.self), discard: discard)
    }

    private func deliver(_ reply: Reply, for ticket: Int32, signalling semaphore: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard abandoned.remove(ticket) == nil else {
            pending.remove(ticket)
            reply.discard()
            return
        }
        replies[ticket] = reply
        _ = Self.signalSemaphore(semaphore)
    }

    private struct Reply {
        let json: String
        let discard: @Sendable () -> Void
    }
}

public struct PharoHeldResult: @unchecked Sendable {
    public let value: Any
    public let release: @Sendable () -> Void

    public init(value: Any, release: @escaping @Sendable () -> Void) {
        self.value = value
        self.release = release
    }
}

public enum PharoAsyncBridgeError: LocalizedError {
    case notServing
    case malformedRequest
    case unknownOperation(String)
    case missingArgument(String)

    public var errorDescription: String? {
        switch self {
        case .notServing:
            return "The host is not serving requests yet."
        case .malformedRequest:
            return "The request is not a JSON object."
        case .unknownOperation(let operation):
            return "Unknown operation \(operation)."
        case .missingArgument(let name):
            return "Missing or invalid \(name)."
        }
    }
}

@_cdecl("luma_async_start")
public func luma_async_start(_ request: UnsafePointer<CChar>, _ semaphore: Int32) -> Int32 {
    PharoAsyncBridge.shared.start(String(cString: request), semaphore: Int(semaphore))
}

@_cdecl("luma_async_take")
public func luma_async_take(_ ticket: Int32) -> UnsafeMutablePointer<CChar>? {
    PharoAsyncBridge.shared.take(ticket)
}

@_cdecl("luma_async_abandon")
public func luma_async_abandon(_ ticket: Int32) {
    PharoAsyncBridge.shared.abandon(ticket)
}
