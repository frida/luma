import Foundation

public struct InstrumentAddressDecoration: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let help: String?

    public init(id: UUID = UUID(), help: String?) {
        self.id = id
        self.help = help
    }
}

public struct AddressAnnotation: Sendable {
    public var decorations: [InstrumentAddressDecoration] = []
    public var tracerHookID: UUID? = nil
    public var chatIDs: [UUID] = []

    public init(
        decorations: [InstrumentAddressDecoration] = [],
        tracerHookID: UUID? = nil,
        chatIDs: [UUID] = []
    ) {
        self.decorations = decorations
        self.tracerHookID = tracerHookID
        self.chatIDs = chatIDs
    }
}
