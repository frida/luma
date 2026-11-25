import LumaCore
import SwiftUI

extension View {
    func childSelectionRequests(engine: Engine) -> some View {
        onChange(of: engine.childSelectionRequest, initial: true) { _, request in
            guard let request else { return }
            engine.setSidebarExpansion(sessionID: request.sessionID, .expanded)
            engine.setHooksExpansion(sessionID: request.sessionID, instrumentID: request.instanceID, .expanded)
            engine.selectedSidebarItem = request.child.map { .instrumentChild(request.sessionID, request.instanceID, $0) }
                ?? .instrument(request.sessionID, request.instanceID)
            engine.consumeChildSelectionRequest()
        }
    }
}
