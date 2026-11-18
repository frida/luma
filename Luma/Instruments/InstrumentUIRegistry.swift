import Foundation
import LumaCore

@MainActor
final class InstrumentUIRegistry {
    static let shared = InstrumentUIRegistry()

    private var uis: [String: InstrumentUI] = [:]

    func registerGlobalDefaults() {
        register(for: "tracer", ui: TracerUI())
        register(for: "codeshare", ui: CodeShareUI())
    }

    func register(for descriptorID: String, ui: InstrumentUI) {
        uis[descriptorID] = ui
    }

    func ui(for instance: LumaCore.InstrumentInstance) -> InstrumentUI? {
        switch instance.kind {
        case .tracer:
            return uis["tracer"]
        case .codeShare:
            return uis["codeshare:\(instance.sourceIdentifier)"] ?? uis["codeshare"]
        case .custom:
            return uis["custom:\(instance.sourceIdentifier)"] ?? uis["custom"]
        }
    }

    func ui(for descriptorID: String) -> InstrumentUI? {
        uis[descriptorID]
    }
}
