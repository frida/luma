public actor AsyncEventSource<Event: Sendable> {
    public typealias Stream = AsyncStream<Event>

    private var nextID: Int = 0
    private var continuations: [Int: Stream.Continuation] = [:]
    private var isFinished = false
    private var terminalEvent: Event? = nil

    public init() {}

    public nonisolated func makeStream() -> Stream {
        Stream { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public nonisolated func yield(_ event: Event) {
        Task { await self.emit(event) }
    }

    public nonisolated func finish(replayLast last: Event? = nil) {
        Task { await self.finishAll(replayLast: last) }
    }

    private func addSubscriber(_ continuation: Stream.Continuation) {
        if isFinished {
            if let event = terminalEvent {
                continuation.yield(event)
            }
            continuation.finish()
            return
        }

        let id = nextID
        nextID &+= 1
        continuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id) }
        }
    }

    private func removeSubscriber(_ id: Int) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: Event) {
        if isFinished { return }

        for c in continuations.values {
            c.yield(event)
        }
    }

    private func finishAll(replayLast last: Event?) {
        if isFinished { return }

        isFinished = true
        terminalEvent = last

        let subs = Array(continuations.values)
        continuations.removeAll()

        for c in subs {
            if let event = last {
                c.yield(event)
            }
            c.finish()
        }
    }
}
