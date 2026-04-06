import Foundation
import LumaCore

struct RuntimeEvent: Identifiable {
    enum Source {
        case processOutput(process: ProcessNode, fd: Int)
        case script(process: ProcessNode)
        case console(process: ProcessNode)
        case repl(process: ProcessNode)
        case instrument(process: ProcessNode, instrument: InstrumentRuntime)
    }

    let id = UUID()
    let timestamp = Date()
    let source: Source
    let payload: Any
    let data: [UInt8]?

    var process: ProcessNode {
        switch source {
        case .processOutput(let process, _),
            .script(let process),
            .console(let process),
            .repl(let process),
            .instrument(let process, _):
            return process
        }
    }
}


