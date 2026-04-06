import Foundation

public func parseAgentHexAddress(_ s: String) throws -> UInt64 {
    guard s.hasPrefix("0x") else {
        throw LumaCoreError.invalidArgument("Invalid address string from agent: '\(s)'")
    }

    guard let value = UInt64(s.dropFirst(2), radix: 16) else {
        throw LumaCoreError.invalidArgument("Invalid address string from agent: '\(s)'")
    }

    return value
}
