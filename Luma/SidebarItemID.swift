import Foundation
import LumaCore

enum SidebarItemID: Codable, Hashable {
    case notebook
    case missions
    case mission(UUID)
    case session(UUID)
    case repl(UUID)
    case instrument(UUID, UUID)
    case instrumentComponent(UUID, UUID, UUID)
    case insight(UUID, UUID)
    case itrace(UUID, UUID)
    case package(UUID)
    case customInstrumentDef(UUID)
    case customInstrumentFile(UUID, String)
}
