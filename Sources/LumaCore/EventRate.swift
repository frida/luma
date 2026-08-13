import Foundation

/// Converts event-log arrivals into the 0..1 activity a shader effect reacts
/// to. Answers nil while nothing is arriving, so a caller only touches the
/// effect when there is news; the effect decays what it was last told.
@MainActor
public final class EventRate {
    /// Events per second that reads as fully busy.
    private let saturatingRate: Float = 40

    private var lastTotal: Int?
    private var lastObservedAt: TimeInterval = 0

    public init() {}

    public func observe(totalReceived: Int, at now: TimeInterval) -> Float? {
        defer {
            lastTotal = totalReceived
            lastObservedAt = now
        }
        guard let previousTotal = lastTotal, totalReceived > previousTotal else { return nil }

        let elapsed = Float(now - lastObservedAt)
        let arrived = Float(totalReceived - previousTotal)
        return min(arrived / max(elapsed, 0.001) / saturatingRate, 1)
    }

    public func reset() {
        lastTotal = nil
    }
}
