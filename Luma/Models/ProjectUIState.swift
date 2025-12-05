import Foundation
import SwiftData

@Model
final class ProjectUIState {
    var selectedItemID: SidebarItemID?

    var isEventStreamCollapsed: Bool
    var eventStreamBottomHeight: Double

    init(
        selectedItemID: SidebarItemID? = nil,
        isEventStreamCollapsed: Bool = true,
        eventStreamBottomHeight: Double = 0,
    ) {
        self.selectedItemID = selectedItemID
        self.isEventStreamCollapsed = isEventStreamCollapsed
        self.eventStreamBottomHeight = eventStreamBottomHeight
    }
}

enum SidebarItemID: Codable, Hashable {
    case notebook
    case repl(UUID)
    case instrument(UUID, UUID)
    case instrumentComponent(UUID, UUID, UUID, UUID)
    case package(UUID)
}
