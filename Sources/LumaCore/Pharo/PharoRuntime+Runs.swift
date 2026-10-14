import Foundation
import SwiftyPharo

extension PharoRuntime {
    public func evaluate(_ source: String, runningFor owner: UUID) async throws -> PharoObject {
        try await run("LumaRun begin: '\(owner.uuidString)'")
        do {
            let produced = try await evaluate(source)
            try await run("LumaRun end")
            return produced
        } catch {
            try? await run("LumaRun end")
            throw error
        }
    }

    public func stopRun(_ owner: UUID) async throws {
        try await run("LumaRun stop: '\(owner.uuidString)'")
    }

    private func run(_ source: String) async throws {
        try await release(try await evaluate(source))
    }
}
