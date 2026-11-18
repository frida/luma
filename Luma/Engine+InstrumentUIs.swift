import Foundation
import LumaCore

extension Engine {
    func attachInstrumentUIs() {
        guard enginesWithInstrumentUIs.insert(ObjectIdentifier(self)).inserted else { return }

        refreshCustomInstrumentUIs()
        customInstruments.observers.append { [weak self] in
            self?.refreshCustomInstrumentUIs()
        }
    }

    private func refreshCustomInstrumentUIs() {
        let registry = InstrumentUIRegistry.shared
        for def in customInstruments.defs {
            registry.register(
                for: "custom:\(def.id.uuidString)",
                ui: CustomInstrumentUI(defID: def.id)
            )
        }
    }
}

@MainActor
private var enginesWithInstrumentUIs: Set<ObjectIdentifier> = []
