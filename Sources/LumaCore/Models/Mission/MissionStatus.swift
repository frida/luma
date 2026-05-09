import Foundation

public enum MissionStatus: String, Codable, Sendable, CaseIterable {
    case drafting
    case running
    case awaitingApproval = "awaiting_approval"
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .drafting, .running, .awaitingApproval, .paused: return false
        }
    }

    public var isLive: Bool { !isTerminal }
}

public enum MissionActionStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case approved
    case rejected
    case running
    case succeeded
    case failed
}

public enum MissionFindingConfidence: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum MissionFindingStatus: String, Codable, Sendable, CaseIterable {
    case proposed
    case accepted
    case refuted
    case superseded
}

public enum MissionTurnRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case tool
}

public enum MissionEvidenceKind: String, Codable, Sendable, CaseIterable {
    case event
    case hookHit = "hook_hit"
    case disasmSpan = "disasm_span"
    case memoryRead = "memory_read"
    case symbolMatch = "symbol_match"
    case insight
    case action
}
