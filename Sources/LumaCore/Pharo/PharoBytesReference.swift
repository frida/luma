import Foundation

public struct PharoBytesReference: Sendable {
    public let address: UInt64
    public let data: Data

    public init?(_ reference: String) {
        guard let separator = reference.firstIndex(of: ":"),
            let address = UInt64(reference[..<separator].dropFirst(2), radix: 16),
            let data = Data(base64Encoded: String(reference[reference.index(after: separator)...]))
        else { return nil }
        self.address = address
        self.data = data
    }
}
