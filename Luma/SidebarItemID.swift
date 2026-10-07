import Foundation
import LumaCore

enum SidebarItemID: Codable, Hashable {
    case notebook
    case pharo
    case missions
    case mission(UUID)
    case patterns
    case pattern(String)
    case patternType(String, String)
    case session(UUID)
    case repl(UUID)
    case files(UUID)
    case module(UUID, String)
    case thread(UUID, UInt)
    case instrument(UUID, UUID)
    case instrumentComponent(UUID, UUID, UUID)
    case insight(UUID, UUID)
    case itrace(UUID, UUID)
    case package(UUID)
    case customInstrumentDef(UUID)
    case customInstrumentFile(UUID, String)
}
