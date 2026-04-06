import Foundation
import LumaCore

struct DisplayEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let processNode: ProcessNodeViewModel
    let instrument: InstrumentRuntime?
    let coreEvent: LumaCore.RuntimeEvent

    init(coreEvent: LumaCore.RuntimeEvent, processNode: ProcessNodeViewModel, instrument: InstrumentRuntime? = nil) {
        self.id = coreEvent.id
        self.timestamp = coreEvent.timestamp
        self.processNode = processNode
        self.instrument = instrument
        self.coreEvent = coreEvent
    }

    var source: LumaCore.RuntimeEvent.Source { coreEvent.source }
    var payload: LumaCore.RuntimeEvent.Payload { coreEvent.payload }
    var data: [UInt8]? { coreEvent.data }
}
