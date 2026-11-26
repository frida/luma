import Observation

@Observable
@MainActor
public final class EventLog {
    public private(set) var events: [RuntimeEvent] = []
    public private(set) var totalReceived: Int = 0
    public private(set) var flushVersion: Int = 0
    public private(set) var updateVersion: Int = 0
    public private(set) var lastUpdated: RuntimeEvent?

    public let maxVisible: Int
    public let maxInMemory: Int

    @ObservationIgnored public var onEventsAppended: ((@MainActor (ArraySlice<RuntimeEvent>) -> Void))?
    @ObservationIgnored public var onEventUpdated: ((@MainActor (RuntimeEvent) -> Void))?
    @ObservationIgnored public var onEventsCleared: ((@MainActor () -> Void))?
    @ObservationIgnored public var onEventsToPersist: ((@MainActor ([RuntimeEvent]) -> Void))?
    @ObservationIgnored private var allEvents: [RuntimeEvent] = []
    @ObservationIgnored private var arrived: [RuntimeEvent] = []
    @ObservationIgnored private var pendingPersist: [RuntimeEvent] = []
    @ObservationIgnored private var isFlushScheduled = false

    private static let flushInterval = Duration.milliseconds(100)

    public init(maxVisible: Int = 1_000, maxInMemory: Int = 10_000) {
        self.maxVisible = maxVisible
        self.maxInMemory = maxInMemory
    }

    public func append(_ event: RuntimeEvent) {
        arrived.append(event)
        scheduleFlush()
    }

    public func event(id: RuntimeEvent.ID) -> RuntimeEvent? {
        arrived.last { $0.id == id } ?? allEvents.last { $0.id == id }
    }

    public func update(_ event: RuntimeEvent) {
        if let index = arrived.lastIndex(where: { $0.id == event.id }) {
            var revised = event
            revised.revision = arrived[index].revision &+ 1
            arrived[index] = revised
            return
        }
        guard let index = allEvents.lastIndex(where: { $0.id == event.id }) else { return }
        var revised = event
        revised.revision = allEvents[index].revision &+ 1
        allEvents[index] = revised
        if let visibleIndex = events.lastIndex(where: { $0.id == event.id }) {
            events[visibleIndex] = revised
        }
        lastUpdated = revised
        updateVersion &+= 1
        pendingPersist.append(revised)
        persistPending()
        onEventUpdated?(revised)
    }

    public func restore(_ events: [RuntimeEvent]) {
        allEvents = Array(events.suffix(maxInMemory))
        totalReceived = events.count
        self.events = Array(allEvents.suffix(maxVisible))
        flushVersion &+= 1
    }

    public func clear() {
        allEvents.removeAll()
        arrived.removeAll()
        events.removeAll()
        pendingPersist.removeAll()
        totalReceived = 0
        flushVersion = 0
        isFlushScheduled = false
        onEventsCleared?()
    }

    public func flushNow() {
        isFlushScheduled = false
        flush()
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true

        Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        if !arrived.isEmpty {
            let batch = arrived
            arrived.removeAll(keepingCapacity: true)
            allEvents.append(contentsOf: batch)
            if allEvents.count > maxInMemory {
                allEvents.removeFirst(allEvents.count - maxInMemory)
            }
            pendingPersist.append(contentsOf: batch)
            let visible = Array(allEvents.suffix(maxVisible))
            events = visible
            totalReceived += batch.count
            flushVersion &+= 1
            onEventsAppended?(visible.suffix(batch.count))
        }
        persistPending()
    }

    private func persistPending() {
        guard !pendingPersist.isEmpty else { return }
        let batch = pendingPersist
        pendingPersist.removeAll(keepingCapacity: true)
        onEventsToPersist?(batch)
    }
}
