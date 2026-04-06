import Foundation

public struct AddressInsight: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var title: String
    public var kind: Kind
    public var anchor: AddressAnchor
    public var byteCount: Int
    public var lastResolvedAddress: UInt64?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        title: String,
        kind: Kind,
        anchor: AddressAnchor,
        byteCount: Int = 0x200
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = Date()
        self.title = title
        self.kind = kind
        self.anchor = anchor
        self.byteCount = byteCount
    }

    public enum Kind: Int, Codable, Sendable {
        case memory
        case disassembly
    }
}
