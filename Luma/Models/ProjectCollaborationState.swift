import Foundation
import SwiftData

@Model
final class ProjectCollaborationState {
    var id: UUID
    var roomID: String?

    init(roomID: String? = nil) {
        self.id = UUID()
        self.roomID = roomID
    }
}
