import Foundation
import Synchronization

public struct PharoPatternDecoding: Sendable {
    public let root: DecodedPattern
    public let data: Data
    public let address: UInt64
}

public final class PharoPatternRegistry: Sendable {
    public static let shared = PharoPatternRegistry()

    private let state = Mutex(State())

    private struct State {
        var decodings: [Int: PharoPatternDecoding] = [:]
        var nextID = 1
    }

    public func register(_ decoding: PharoPatternDecoding) -> Int {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.decodings[id] = decoding
            return id
        }
    }

    public func decoding(withID id: Int) -> PharoPatternDecoding? {
        state.withLock { $0.decodings[id] }
    }

    func release(_ id: Int) {
        state.withLock { state in
            state.decodings[id] = nil
        }
    }
}

@_cdecl("luma_pattern_release")
public func luma_pattern_release(_ id: Int32) {
    PharoPatternRegistry.shared.release(Int(id))
}
