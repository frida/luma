import Foundation

public struct InstructionContext: Sendable {
    public let insightName: String?
    public let disassembly: String
    public let decompilation: String
}
