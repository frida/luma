import Foundation
import GRDB

public enum SidebarExpansion: String, Codable, Sendable {
    case expanded
    case collapsed
}

public struct SessionUIState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session_ui_state"

    public var sessionID: UUID
    public var sidebarExpansion: SidebarExpansion
    public var detailSection: String?
    public var lastSelectedModuleID: String?
    public var lastSelectedThreadID: UInt?
    public var ambientMissionID: UUID?

    public var id: UUID { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sidebarExpansion = "sidebar_expansion"
        case detailSection = "detail_section"
        case lastSelectedModuleID = "last_selected_module_id"
        case lastSelectedThreadID = "last_selected_thread_id"
        case ambientMissionID = "ambient_mission_id"
    }

    public init(
        sessionID: UUID,
        sidebarExpansion: SidebarExpansion = .expanded,
        detailSection: String? = nil,
        lastSelectedModuleID: String? = nil,
        lastSelectedThreadID: UInt? = nil,
        ambientMissionID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.sidebarExpansion = sidebarExpansion
        self.detailSection = detailSection
        self.lastSelectedModuleID = lastSelectedModuleID
        self.lastSelectedThreadID = lastSelectedThreadID
        self.ambientMissionID = ambientMissionID
    }
}
