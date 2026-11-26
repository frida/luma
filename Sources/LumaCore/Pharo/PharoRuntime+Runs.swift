import Foundation
import SwiftyPharo

extension PharoRuntime {
    public func evaluate(_ source: String, runningFor owner: UUID) async throws -> PharoObject {
        try await run("LumaRun begin: '\(owner.uuidString)'")
        let evaluation = Task { try await evaluate(source) }
        PharoRunEvaluations.shared.start(evaluation, for: owner)
        let ended = Task {
            _ = await evaluation.result
            PharoRunEvaluations.shared.finish(evaluation, for: owner)
            try await run("LumaRun end")
        }
        return try await withTaskCancellationHandler {
            try await ended.value
            return try await evaluation.value
        } onCancel: {
            evaluation.cancel()
        }
    }

    public func stopRun(_ owner: UUID) async throws {
        PharoRunEvaluations.shared.cancel(owner)
        try await run("LumaRun stop: '\(owner.uuidString)'")
    }

    private func run(_ source: String) async throws {
        try await release(try await evaluate(source))
    }
}

private final class PharoRunEvaluations: @unchecked Sendable {
    static let shared = PharoRunEvaluations()

    private let lock = NSLock()
    private var running: [UUID: Set<Task<PharoObject, any Error>>] = [:]

    func start(_ evaluation: Task<PharoObject, any Error>, for owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        running[owner, default: []].insert(evaluation)
    }

    func finish(_ evaluation: Task<PharoObject, any Error>, for owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        running[owner]?.remove(evaluation)
        if running[owner]?.isEmpty == true {
            running[owner] = nil
        }
    }

    func cancel(_ owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        running[owner]?.forEach { $0.cancel() }
    }
}
