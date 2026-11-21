import Foundation
import LumaCore

extension Engine {
    var selectedSidebarItem: SidebarItemID? {
        get { decodedSidebarItem(from: projectUIState.selectedItemJSON) }
        set {
            if let newValue {
                revealInSidebar(newValue)
            }
            setSelectedItemJSON(encodedSidebarItem(newValue))
        }
    }

    private func revealInSidebar(_ item: SidebarItemID) {
        if let sessionID = item.sessionID {
            setSidebarExpansion(sessionID: sessionID, .expanded)
        }
        if let location = item.moduleLocation {
            setSidebarExpansion(sessionID: location.sessionID, moduleID: location.moduleID, .expanded)
        }
        switch item {
        case .swiftType(let sessionID, let moduleID, _):
            setSwiftTypesExpansion(sessionID: sessionID, moduleID: moduleID, .expanded)
        case .pattern(let sourceID), .patternType(let sourceID, _):
            setSidebarExpansion(section: .patterns, .expanded)
            setSidebarExpansion(patternSourceID: sourceID, .expanded)
        default:
            break
        }
    }

    private func decodedSidebarItem(from json: String?) -> SidebarItemID? {
        guard let json,
            let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(SidebarItemID.self, from: data)
    }

    private func encodedSidebarItem(_ item: SidebarItemID?) -> String? {
        guard let item,
            let data = try? JSONEncoder().encode(item),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    func lastSelectedModuleID(for sessionID: UUID) -> String? {
        lastSelectedModuleID(forSessionID: sessionID)
    }

    func lastSelectedThreadID(for sessionID: UUID) -> UInt? {
        lastSelectedThreadID(forSessionID: sessionID)
    }
}

extension SidebarItemID {
    init(navigationTarget target: NavigationTarget) {
        switch target {
        case .instrumentComponent(let sid, let iid, let cid):
            self = .instrumentComponent(sid, iid, cid)
        case .itrace(let sid, let tid):
            self = .itrace(sid, tid)
        }
    }
}
