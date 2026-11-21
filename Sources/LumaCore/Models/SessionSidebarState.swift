import Foundation
import GRDB

public struct SessionSidebarState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session_sidebar_state"

    public var sessionID: UUID
    public var expandedModules: Set<String>
    public var expandedSwiftTypeLists: Set<String>

    public var id: UUID { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case expandedModules = "expanded_modules"
        case expandedSwiftTypeLists = "expanded_swift_type_lists"
    }

    public init(
        sessionID: UUID,
        expandedModules: Set<String> = [],
        expandedSwiftTypeLists: Set<String> = []
    ) {
        self.sessionID = sessionID
        self.expandedModules = expandedModules
        self.expandedSwiftTypeLists = expandedSwiftTypeLists
    }
}
