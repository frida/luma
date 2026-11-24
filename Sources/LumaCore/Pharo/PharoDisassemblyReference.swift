import Foundation

public struct PharoDisassemblyReference: Sendable {
    public let sessionID: UUID
    public let address: UInt64

    public init?(_ reference: String) {
        guard let separator = reference.firstIndex(of: ":"),
            let sessionID = UUID(uuidString: String(reference[..<separator])),
            let address = UInt64(reference[reference.index(after: separator)...].dropFirst(2), radix: 16)
        else { return nil }
        self.sessionID = sessionID
        self.address = address
    }
}
