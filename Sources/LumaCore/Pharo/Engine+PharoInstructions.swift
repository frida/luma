import Foundation
import SwiftyPharo

extension Engine {
    public func instruction(at address: UInt64, in sessionID: UUID, runtime: PharoRuntime) async throws -> PharoObject {
        try await runtime.evaluate("\(Self.pharoSession(sessionID)) instructionAt: \(address)")
    }

    static func pharoSession(_ sessionID: UUID) -> String {
        "(LumaProject sessions items detect: [ :each | each id = '\(sessionID.uuidString)' ]"
            + " ifNone: [ Error signal: 'The session is not in this project.' ])"
    }
}
