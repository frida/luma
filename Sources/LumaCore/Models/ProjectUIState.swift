import Foundation
import GRDB

public struct ProjectUIState: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_ui_state"

    public var id: UUID
    public var selectedItemJSON: String?
    public var isEventStreamCollapsed: Bool
    public var eventStreamBottomHeight: Double
    public var isCollaborationPanelVisible: Bool
    public var lastMissionProviderID: String
    public var lastMissionModelID: String
    public var lastMissionTokenBudgetInput: Int
    public var lastMissionTokenBudgetOutput: Int
    public var lastMissionThinkingEnabled: Bool
    public var lastMissionThinkingBudget: Int

    enum CodingKeys: String, CodingKey {
        case id
        case selectedItemJSON = "selected_item_json"
        case isEventStreamCollapsed = "event_stream_collapsed"
        case eventStreamBottomHeight = "event_stream_bottom_height"
        case isCollaborationPanelVisible = "collaboration_panel_visible"
        case lastMissionProviderID = "last_mission_provider_id"
        case lastMissionModelID = "last_mission_model_id"
        case lastMissionTokenBudgetInput = "last_mission_token_budget_input"
        case lastMissionTokenBudgetOutput = "last_mission_token_budget_output"
        case lastMissionThinkingEnabled = "last_mission_thinking_enabled"
        case lastMissionThinkingBudget = "last_mission_thinking_budget"
    }

    public init(
        id: UUID = UUID(),
        selectedItemJSON: String? = nil,
        isEventStreamCollapsed: Bool = true,
        eventStreamBottomHeight: Double = 0,
        isCollaborationPanelVisible: Bool = false,
        lastMissionProviderID: String = "claude-code",
        lastMissionModelID: String = "default",
        lastMissionTokenBudgetInput: Int = 250_000,
        lastMissionTokenBudgetOutput: Int = 32_000,
        lastMissionThinkingEnabled: Bool = false,
        lastMissionThinkingBudget: Int = 4_096
    ) {
        self.id = id
        self.selectedItemJSON = selectedItemJSON
        self.isEventStreamCollapsed = isEventStreamCollapsed
        self.eventStreamBottomHeight = eventStreamBottomHeight
        self.isCollaborationPanelVisible = isCollaborationPanelVisible
        self.lastMissionProviderID = lastMissionProviderID
        self.lastMissionModelID = lastMissionModelID
        self.lastMissionTokenBudgetInput = lastMissionTokenBudgetInput
        self.lastMissionTokenBudgetOutput = lastMissionTokenBudgetOutput
        self.lastMissionThinkingEnabled = lastMissionThinkingEnabled
        self.lastMissionThinkingBudget = lastMissionThinkingBudget
    }
}
