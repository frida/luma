import Foundation
import GRDB

public struct ProjectUIState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_ui_state"

    public var id: UUID
    public var selectedItemJSON: String?
    public var isEventStreamCollapsed: Bool
    public var eventStreamBottomHeight: Double
    public var isCollaborationPanelVisible: Bool
    public var pharoSnippetsJSON: String?

    enum CodingKeys: String, CodingKey {
        case id
        case selectedItemJSON = "selected_item_json"
        case isEventStreamCollapsed = "event_stream_collapsed"
        case eventStreamBottomHeight = "event_stream_bottom_height"
        case isCollaborationPanelVisible = "collaboration_panel_visible"
        case pharoSnippetsJSON = "pharo_snippets_json"
    }

    public init(
        id: UUID = UUID(),
        selectedItemJSON: String? = nil,
        isEventStreamCollapsed: Bool = true,
        eventStreamBottomHeight: Double = 0,
        isCollaborationPanelVisible: Bool = false,
        pharoSnippetsJSON: String? = nil
    ) {
        self.id = id
        self.selectedItemJSON = selectedItemJSON
        self.isEventStreamCollapsed = isEventStreamCollapsed
        self.eventStreamBottomHeight = eventStreamBottomHeight
        self.isCollaborationPanelVisible = isCollaborationPanelVisible
        self.pharoSnippetsJSON = pharoSnippetsJSON
    }
}
