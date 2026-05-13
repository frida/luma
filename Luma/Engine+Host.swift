import Foundation
import LumaCore

extension Engine {
    var selectedSidebarItem: SidebarItemID? {
        get { decodedSidebarItem(from: projectUIState.selectedItemJSON) }
        set { setSelectedItemJSON(encodedSidebarItem(newValue)) }
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

    func sessionDetailSection(for sessionID: UUID) -> SessionDetailSection {
        guard let raw = sessionDetailSectionRaw(forSessionID: sessionID),
            let section = SessionDetailSection(rawValue: raw)
        else { return .summary }
        return section
    }

    func setSessionDetailSection(sessionID: UUID, section: SessionDetailSection) {
        setSessionDetailSection(sessionID: sessionID, section: section.rawValue)
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
