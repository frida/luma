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
    case moduleSymbols(UUID, String, ModuleSymbolCategory)
    case swiftTypes(UUID, String)
    case swiftType(UUID, String, SwiftTypeSummary)
    case thread(UUID, UInt)
    case instrument(UUID, UUID)
    case instrumentComponent(UUID, UUID, UUID)
    case insight(UUID, UUID)
    case itrace(UUID, UUID)
    case package(UUID)
    case customInstrumentDef(UUID)
    case customInstrumentFile(UUID, String)
}

extension SidebarItemID {
    var sessionID: UUID? {
        switch self {
        case .session(let id),
            .repl(let id),
            .files(let id),
            .module(let id, _),
            .moduleSymbols(let id, _, _),
            .swiftTypes(let id, _),
            .swiftType(let id, _, _),
            .thread(let id, _),
            .instrument(let id, _),
            .instrumentComponent(let id, _, _),
            .insight(let id, _),
            .itrace(let id, _):
            return id
        default:
            return nil
        }
    }

    var moduleLocation: (sessionID: UUID, moduleID: String)? {
        switch self {
        case .module(let sessionID, let moduleID),
            .moduleSymbols(let sessionID, let moduleID, _),
            .swiftTypes(let sessionID, let moduleID),
            .swiftType(let sessionID, let moduleID, _):
            return (sessionID, moduleID)
        default:
            return nil
        }
    }
}
