import Foundation

public struct TargetPickerState: Codable, Identifiable, Sendable {
    public var id: UUID
    public var lastSelectedDeviceID: String?
    public var lastModeRaw: String?
    public var lastSpawnSubmodeRaw: String?
    public var lastSpawnApplicationID: String?
    public var lastSpawnProgramPath: String?
    public var lastSelectedProcessName: String?

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
