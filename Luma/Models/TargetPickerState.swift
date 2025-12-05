import Foundation
import SwiftData

@Model
final class TargetPickerState {
    var id: UUID

    var lastSelectedDeviceID: String?

    var lastModeRaw: String?

    var lastSpawnSubmodeRaw: String?
    var lastSpawnApplicationID: String?
    var lastSpawnProgramPath: String?

    var lastSelectedProcessName: String?

    init(
        lastSelectedDeviceID: String? = nil,
        lastModeRaw: String? = nil,
        lastSpawnSubmodeRaw: String? = nil,
        lastSpawnApplicationID: String? = nil,
        lastSpawnProgramPath: String? = nil,
        lastSelectedProcessName: String? = nil
    ) {
        self.id = UUID()

        self.lastSelectedDeviceID = lastSelectedDeviceID

        self.lastModeRaw = lastModeRaw

        self.lastSpawnSubmodeRaw = lastSpawnSubmodeRaw
        self.lastSpawnApplicationID = lastSpawnApplicationID
        self.lastSpawnProgramPath = lastSpawnProgramPath

        self.lastSelectedProcessName = lastSelectedProcessName
    }
}
