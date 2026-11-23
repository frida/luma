import Synchronization

public final class AsyncEventSource<Event: Sendable>: Sendable {
    public typealias Stream = AsyncStream<Event>

    private let state = Mutex(State())

    private struct State {
        var nextID = 0
        var subscribers: [Int: Stream.Continuation] = [:]
        var phase = Phase.open
    }

    private enum Phase {
        case open
        case finished(replaying: Event?)
    }

    public init() {}

    public func makeStream() -> Stream {
        let (stream, continuation) = Stream.makeStream()
        subscribe(continuation)
        return stream
    }

    public func yield(_ event: Event) {
        state.withLock { state in
            guard case .open = state.phase else { return }
            for subscriber in state.subscribers.values {
                subscriber.yield(event)
            }
        }
    }

    public func finish(replayLast last: Event? = nil) {
        let subscribers = state.withLock { state -> [Stream.Continuation] in
            guard case .open = state.phase else { return [] }
            state.phase = .finished(replaying: last)
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers {
            end(subscriber, replaying: last)
        }
    }

    private func subscribe(_ continuation: Stream.Continuation) {
        let admission = state.withLock { state -> Admission in
            switch state.phase {
            case .open:
                let id = state.nextID
                state.nextID &+= 1
                state.subscribers[id] = continuation
                return .subscribed(id: id)
            case .finished(let last):
                return .finished(replaying: last)
            }
        }
        switch admission {
        case .subscribed(let id):
            continuation.onTermination = { [weak self] _ in
                self?.unsubscribe(id)
            }
        case .finished(let last):
            end(continuation, replaying: last)
        }
    }

    private enum Admission {
        case subscribed(id: Int)
        case finished(replaying: Event?)
    }

    private func unsubscribe(_ id: Int) {
        _ = state.withLock { state in
            state.subscribers.removeValue(forKey: id)
        }
    }

    private func end(_ continuation: Stream.Continuation, replaying last: Event?) {
        if let last {
            continuation.yield(last)
        }
        continuation.finish()
    }
}
