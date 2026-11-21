import Foundation
import GRDB

public enum SidebarSection: String, Codable, Sendable {
    case missions
    case patterns
    case sessions
    case customInstruments = "custom_instruments"
    case packages
}

public struct ProjectSidebarState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_sidebar_state"

    public var id: UUID
    public var collapsedSections: Set<SidebarSection>
    public var expandedPatternSources: Set<String>

    enum CodingKeys: String, CodingKey {
        case id
        case collapsedSections = "collapsed_sections"
        case expandedPatternSources = "expanded_pattern_sources"
    }

    public init(
        id: UUID = UUID(),
        collapsedSections: Set<SidebarSection> = [],
        expandedPatternSources: Set<String> = []
    ) {
        self.id = id
        self.collapsedSections = collapsedSections
        self.expandedPatternSources = expandedPatternSources
    }
}
