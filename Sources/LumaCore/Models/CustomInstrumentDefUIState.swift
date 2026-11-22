import Foundation
import GRDB

public struct CustomInstrumentDefUIState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_instrument_def_ui_state"

    public var defID: UUID
    public var sidebarExpansion: SidebarExpansion

    public var id: UUID { defID }

    enum CodingKeys: String, CodingKey {
        case defID = "def_id"
        case sidebarExpansion = "sidebar_expansion"
    }

    public init(
        defID: UUID,
        sidebarExpansion: SidebarExpansion = .expanded
    ) {
        self.defID = defID
        self.sidebarExpansion = sidebarExpansion
    }
}
