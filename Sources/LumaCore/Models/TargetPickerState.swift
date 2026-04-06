import Foundation
import GRDB

public struct TargetPickerState: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "target_picker_state"

    public var id: UUID
    public var lastSelectedDeviceID: String?
    public var lastModeRaw: String?
    public var lastSpawnSubmodeRaw: String?
    public var lastSpawnApplicationID: String?
    public var lastSpawnProgramPath: String?
    public var lastSelectedProcessName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case lastSelectedDeviceID = "last_selected_device_id"
        case lastModeRaw = "last_mode_raw"
        case lastSpawnSubmodeRaw = "last_spawn_submode_raw"
        case lastSpawnApplicationID = "last_spawn_application_id"
        case lastSpawnProgramPath = "last_spawn_program_path"
        case lastSelectedProcessName = "last_selected_process_name"
    }

    public init(
        id: UUID = UUID(),
        lastSelectedDeviceID: String? = nil,
        lastModeRaw: String? = nil,
        lastSpawnSubmodeRaw: String? = nil,
        lastSpawnApplicationID: String? = nil,
        lastSpawnProgramPath: String? = nil,
        lastSelectedProcessName: String? = nil
    ) {
        self.id = id
        self.lastSelectedDeviceID = lastSelectedDeviceID
        self.lastModeRaw = lastModeRaw
        self.lastSpawnSubmodeRaw = lastSpawnSubmodeRaw
        self.lastSpawnApplicationID = lastSpawnApplicationID
        self.lastSpawnProgramPath = lastSpawnProgramPath
        self.lastSelectedProcessName = lastSelectedProcessName
    }
}
