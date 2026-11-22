import Foundation
import GRDB

public struct ProjectUIState: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_ui_state"

    private var id = 1
    public var selectedItemJSON: String?
    public var collapsedSections: Set<SidebarSection>
    public var expandedPatternSources: Set<String>
    public var isEventStreamCollapsed: Bool
    public var eventStreamBottomHeight: Double
    public var sidePanel: SidePanel?
    public var pharoSnippetsJSON: String?
    public var pharoPageWidth: Double?
    public var pharoPageMaximized: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case selectedItemJSON = "selected_item_json"
        case collapsedSections = "collapsed_sections"
        case expandedPatternSources = "expanded_pattern_sources"
        case isEventStreamCollapsed = "event_stream_collapsed"
        case eventStreamBottomHeight = "event_stream_bottom_height"
        case sidePanel = "side_panel"
        case pharoSnippetsJSON = "pharo_snippets_json"
        case pharoPageWidth = "pharo_page_width"
        case pharoPageMaximized = "pharo_page_maximized"
    }

    public init(
        selectedItemJSON: String? = nil,
        collapsedSections: Set<SidebarSection> = [],
        expandedPatternSources: Set<String> = [],
        isEventStreamCollapsed: Bool = true,
        eventStreamBottomHeight: Double = 0,
        sidePanel: SidePanel? = nil,
        pharoSnippetsJSON: String? = nil,
        pharoPageWidth: Double? = nil,
        pharoPageMaximized: Bool = false
    ) {
        self.selectedItemJSON = selectedItemJSON
        self.collapsedSections = collapsedSections
        self.expandedPatternSources = expandedPatternSources
        self.isEventStreamCollapsed = isEventStreamCollapsed
        self.eventStreamBottomHeight = eventStreamBottomHeight
        self.sidePanel = sidePanel
        self.pharoSnippetsJSON = pharoSnippetsJSON
        self.pharoPageWidth = pharoPageWidth
        self.pharoPageMaximized = pharoPageMaximized
    }
}

public enum SidebarSection: String, Codable, Sendable {
    case missions
    case patterns
    case sessions
    case customInstruments = "custom_instruments"
    case packages
}

public enum SidePanel: String, Codable, Sendable {
    case collaboration
    case virtualMachines
}
