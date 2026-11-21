import Foundation

public struct StoreInstallation: Codable, Equatable, Sendable {
    public var itemID: String
    public var version: StoreVersion
    public var snapshot: InstrumentFolderLink.Snapshot

    public init(itemID: String, version: StoreVersion, snapshot: InstrumentFolderLink.Snapshot) {
        self.itemID = itemID
        self.version = version
        self.snapshot = snapshot
    }
}
