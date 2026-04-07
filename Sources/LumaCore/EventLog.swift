@MainActor
public final class EventLog {
    public private(set) var events: [RuntimeEvent] = []
    public private(set) var totalReceived: Int = 0

    public let maxVisible: Int
    public let maxInMemory: Int

    private let _changes = AsyncEventSource<Void>()
    public var changes: AsyncStream<Void> { _changes.makeStream() }

    private var allEvents: [RuntimeEvent] = []
    private var isFlushScheduled = false

    public init(maxVisible: Int = 1_000, maxInMemory: Int = 10_000) {
        self.maxVisible = maxVisible
        self.maxInMemory = maxInMemory
    }

    public func append(_ event: RuntimeEvent) {
        totalReceived += 1
        allEvents.append(event)

        if allEvents.count > maxInMemory {
            allEvents.removeFirst(allEvents.count - maxInMemory)
        }

        scheduleFlush()
    }

    public func clear() {
        allEvents.removeAll()
        events.removeAll()
        totalReceived = 0
        isFlushScheduled = false
        _changes.yield(())
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        events = Array(allEvents.suffix(maxVisible))
        _changes.yield(())
    }
}
