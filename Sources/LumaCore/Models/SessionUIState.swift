import Foundation
import GRDB

public enum SidebarExpansion: String, Codable, Sendable {
    case expanded
    case collapsed
}

public enum SessionSidebarGroup: Sendable {
    case modules
    case threads
}

public struct SessionUIState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session_ui_state"

    public var sessionID: UUID
    public var sidebarExpansion: SidebarExpansion
    public var modulesExpansion: SidebarExpansion
    public var threadsExpansion: SidebarExpansion
    public var collapsedHookInstruments: Set<UUID>
    public var expandedModules: Set<String>
    public var expandedSwiftTypeLists: Set<String>
    public var detailSection: String?
    public var lastSelectedModuleID: String?
    public var lastSelectedThreadID: UInt?
    public var ambientMissionID: UUID?
    public var replLanguage: REPLLanguage
    public var replDraft: String?
    public var replSeekAnchor: AddressAnchor?

    public var id: UUID { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sidebarExpansion = "sidebar_expansion"
        case modulesExpansion = "modules_expansion"
        case threadsExpansion = "threads_expansion"
        case collapsedHookInstruments = "collapsed_hook_instruments"
        case expandedModules = "expanded_modules"
        case expandedSwiftTypeLists = "expanded_swift_type_lists"
        case detailSection = "detail_section"
        case lastSelectedModuleID = "last_selected_module_id"
        case lastSelectedThreadID = "last_selected_thread_id"
        case ambientMissionID = "ambient_mission_id"
        case replLanguage = "repl_language"
        case replDraft = "repl_draft"
        case replSeekAnchor = "repl_seek_anchor"
    }

    public init(
        sessionID: UUID,
        sidebarExpansion: SidebarExpansion = .expanded,
        modulesExpansion: SidebarExpansion = .collapsed,
        threadsExpansion: SidebarExpansion = .collapsed,
        collapsedHookInstruments: Set<UUID> = [],
        expandedModules: Set<String> = [],
        expandedSwiftTypeLists: Set<String> = [],
        detailSection: String? = nil,
        lastSelectedModuleID: String? = nil,
        lastSelectedThreadID: UInt? = nil,
        ambientMissionID: UUID? = nil,
        replLanguage: REPLLanguage = .javascript,
        replDraft: String? = nil,
        replSeekAnchor: AddressAnchor? = nil
    ) {
        self.sessionID = sessionID
        self.sidebarExpansion = sidebarExpansion
        self.modulesExpansion = modulesExpansion
        self.threadsExpansion = threadsExpansion
        self.collapsedHookInstruments = collapsedHookInstruments
        self.expandedModules = expandedModules
        self.expandedSwiftTypeLists = expandedSwiftTypeLists
        self.detailSection = detailSection
        self.lastSelectedModuleID = lastSelectedModuleID
        self.lastSelectedThreadID = lastSelectedThreadID
        self.ambientMissionID = ambientMissionID
        self.replLanguage = replLanguage
        self.replDraft = replDraft
        self.replSeekAnchor = replSeekAnchor
    }
}
