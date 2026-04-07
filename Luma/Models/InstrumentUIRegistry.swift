import Foundation
import LumaCore

@MainActor
final class InstrumentUIRegistry {
    static let shared = InstrumentUIRegistry()

    private var uis: [String: InstrumentUI] = [:]

    func register(for descriptorID: String, ui: InstrumentUI) {
        uis[descriptorID] = ui
    }

    func ui(for instance: LumaCore.InstrumentInstance) -> InstrumentUI? {
        switch instance.kind {
        case .tracer:
            return uis["tracer"]
        case .hookPack:
            return uis["hook-pack:\(instance.sourceIdentifier)"]
        case .codeShare:
            return uis["codeshare:\(instance.sourceIdentifier)"] ?? uis["codeshare"]
        }
    }

    func ui(for descriptorID: String) -> InstrumentUI? {
        uis[descriptorID]
    }
}
