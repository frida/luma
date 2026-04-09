import Observation

@Observable
@MainActor
public final class EventLog {
    public private(set) var events: [RuntimeEvent] = []
    public private(set) var totalReceived: Int = 0

    public let maxVisible: Int
    public let maxInMemory: Int

    @ObservationIgnored public var onEventsAppended: ((@MainActor (ArraySlice<RuntimeEvent>) -> Void))?
    @ObservationIgnored public var onEventsCleared: ((@MainActor () -> Void))?
    @ObservationIgnored private var allEvents: [RuntimeEvent] = []
    @ObservationIgnored private var isFlushScheduled = false
    @ObservationIgnored private var lastFlushedCount = 0

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
        lastFlushedCount = 0
        isFlushScheduled = false
        onEventsCleared?()
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
        let visible = Array(allEvents.suffix(maxVisible))
        let newCount = visible.count
        let prevCount = lastFlushedCount
        events = visible
        lastFlushedCount = newCount
        if newCount > prevCount {
            onEventsAppended?(visible[prevCount...])
        }
    }
}
