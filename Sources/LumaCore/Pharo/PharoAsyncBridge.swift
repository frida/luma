import Foundation

#if os(Windows)
import WinSDK
#endif

public final class PharoAsyncBridge: @unchecked Sendable {
    public static let shared = PharoAsyncBridge()

    public typealias Handler = @MainActor (_ request: [String: Any]) async throws -> Any

    private let lock = NSLock()
    private var handler: Handler?
    private var nextTicket: Int32 = 1
    private var tickets: [Int32: Ticket] = [:]

    private static let signalSemaphore = unsafeBitCast(
        vmFunction(named: "signalSemaphoreWithIndex"),
        to: (@convention(c) (Int) -> Int).self)

    private static func vmFunction(named name: String) -> UnsafeRawPointer? {
        #if os(Windows)
        unsafeBitCast(GetProcAddress(GetModuleHandleA("PharoVMCore.dll"), name), to: UnsafeRawPointer?.self)
        #else
        UnsafeRawPointer(dlsym(dlopen(nil, RTLD_NOW), name))
        #endif
    }

    public func serve(with handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    fileprivate func start(_ requestJSON: String, semaphore: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let ticket = nextTicket
        nextTicket += 1
        let handler = handler
        tickets[ticket] = Ticket(answering: Task { @MainActor in
            await self.answer(requestJSON, for: ticket, signalling: semaphore, using: handler)
        })
        return ticket
    }

    fileprivate func take(_ ticket: Int32) -> UnsafeMutablePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        guard var pending = tickets[ticket], !pending.replies.isEmpty else {
            return strdup(#"{"error":"no reply for this ticket"}"#)
        }
        let reply = pending.replies.removeFirst()
        tickets[ticket] = pending.replies.isEmpty && pending.isClosed ? nil : pending
        return strdup(reply.json)
    }

    fileprivate func abandon(_ ticket: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = tickets.removeValue(forKey: ticket) else { return }
        pending.answering.cancel()
        for reply in pending.replies {
            reply.discard()
        }
    }

    @MainActor
    private func answer(_ requestJSON: String, for ticket: Int32, signalling semaphore: Int, using handler: Handler?) async {
        switch await Self.outcome(of: requestJSON, using: handler) {
        case .once(let reply):
            deliver(reply, for: ticket, signalling: semaphore, closing: true)
        case .stream(let items):
            for await item in items {
                deliver(Self.encode(["result": item]), for: ticket, signalling: semaphore, closing: false)
            }
            deliver(Self.encode(["end": true]), for: ticket, signalling: semaphore, closing: true)
        }
    }

    @MainActor
    private static func outcome(of requestJSON: String, using handler: Handler?) async -> Outcome {
        do {
            guard let handler else { throw PharoAsyncBridgeError.notServing }
            guard let request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any] else {
                throw PharoAsyncBridgeError.malformedRequest
            }
            let result = try await handler(request)
            if let streamed = result as? PharoStreamedResult {
                return .stream(streamed.items)
            }
            if let held = result as? PharoHeldResult {
                return .once(encode(["result": held.value], discard: held.release))
            }
            return .once(encode(["result": result]))
        } catch {
            return .once(encode(["error": error.localizedDescription]))
        }
    }

    private static func encode(_ envelope: [String: Any], discard: @escaping @Sendable () -> Void = {}) -> Reply {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.fragmentsAllowed]) else {
            discard()
            return Reply(json: #"{"error":"the reply could not be encoded"}"#, discard: {})
        }
        return Reply(json: String(decoding: data, as: UTF8.self), discard: discard)
    }

    private func deliver(_ reply: Reply, for ticket: Int32, signalling semaphore: Int, closing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var pending = tickets[ticket] else {
            reply.discard()
            return
        }
        pending.replies.append(reply)
        pending.isClosed = closing
        tickets[ticket] = pending
        _ = Self.signalSemaphore(semaphore)
    }

    private struct Ticket {
        let answering: Task<Void, Never>
        var replies: [Reply] = []
        var isClosed = false
    }

    private enum Outcome {
        case once(Reply)
        case stream(AsyncStream<Any>)
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

public struct PharoStreamedResult: @unchecked Sendable {
    public let items: AsyncStream<Any>

    public init(items: AsyncStream<Any>) {
        self.items = items
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
