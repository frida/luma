import Foundation
import Observation

public struct ConnectionStage: Sendable, Equatable {
    public let status: String
    public let fraction: Double
    public let expectedDuration: TimeInterval

    public init(status: String, fraction: Double, expectedDuration: TimeInterval) {
        self.status = status
        self.fraction = fraction
        self.expectedDuration = expectedDuration
    }
}

@MainActor
@Observable
public final class ConnectionActivityCenter {
    public private(set) var stages: [String: ConnectionStage] = [:]

    @ObservationIgnored private let durations: StageDurationMemory
    @ObservationIgnored private var arrivals: [String: StageArrival] = [:]

    private struct StageArrival {
        let key: String
        let at: Date
    }

    public init(durations: StageDurationMemory) {
        self.durations = durations
    }

    public func stage(for deviceID: String) -> ConnectionStage? {
        stages[deviceID]
    }

    public func report(deviceID: String, deviceKind: String, status: String, fraction: Double) {
        recordElapsed(for: deviceID)

        let key = "\(deviceKind)/\(status)"
        stages[deviceID] = ConnectionStage(
            status: status,
            fraction: fraction,
            expectedDuration: durations.expectedDuration(forKey: key)
        )
        arrivals[deviceID] = StageArrival(key: key, at: Date())
    }

    public func complete(deviceID: String) {
        recordElapsed(for: deviceID)
        stages[deviceID] = nil
    }

    private func recordElapsed(for deviceID: String) {
        guard let arrival = arrivals.removeValue(forKey: deviceID) else { return }
        durations.record(elapsed: Date().timeIntervalSince(arrival.at), forKey: arrival.key)
    }
}
