import Foundation
import GRDB

public struct ProjectUIState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_ui_state"

    public var id: UUID
    public var selectedItemJSON: String?
    public var isEventStreamCollapsed: Bool
    public var eventStreamBottomHeight: Double
    public var sidePanel: SidePanel?
    public var pharoSnippetsJSON: String?
    public var pharoPageWidth: Double?
    public var pharoPageMaximized: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case selectedItemJSON = "selected_item_json"
        case isEventStreamCollapsed = "event_stream_collapsed"
        case eventStreamBottomHeight = "event_stream_bottom_height"
        case sidePanel = "side_panel"
        case pharoSnippetsJSON = "pharo_snippets_json"
        case pharoPageWidth = "pharo_page_width"
        case pharoPageMaximized = "pharo_page_maximized"
    }

    public init(
        id: UUID = UUID(),
        selectedItemJSON: String? = nil,
        isEventStreamCollapsed: Bool = true,
        eventStreamBottomHeight: Double = 0,
        sidePanel: SidePanel? = nil,
        pharoSnippetsJSON: String? = nil,
        pharoPageWidth: Double? = nil,
        pharoPageMaximized: Bool = false
    ) {
        self.id = id
        self.selectedItemJSON = selectedItemJSON
        self.isEventStreamCollapsed = isEventStreamCollapsed
        self.eventStreamBottomHeight = eventStreamBottomHeight
        self.sidePanel = sidePanel
        self.pharoSnippetsJSON = pharoSnippetsJSON
        self.pharoPageWidth = pharoPageWidth
        self.pharoPageMaximized = pharoPageMaximized
    }
}

public enum SidePanel: String, Codable, Sendable {
    case collaboration
    case virtualMachines
}
