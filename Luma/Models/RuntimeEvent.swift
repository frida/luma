import Foundation

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
}

struct JSError: CustomStringConvertible {
    let text: String

    let fileName: String?
    let lineNumber: Int?
    let columnNumber: Int?

    let stack: String?

    var description: String {
        var base = text
        if let fileName, let lineNumber {
            base += " (\(fileName):\(lineNumber)"
            if let columnNumber {
                base += ":\(columnNumber)"
            }
            base += ")"
        }
        if let stack, !stack.isEmpty {
            base += "\n" + stack
        }
        return base
    }
}

struct ConsoleMessage: CustomStringConvertible {
    let level: ConsoleLevel
    let values: [JSInspectValue]

    var description: String {
        let body =
            values
            .map { String(describing: $0) }
            .joined(separator: " ")
        return "[\(level.rawValue)] \(body)"
    }
}

enum ConsoleLevel: String {
    case info
    case debug
    case warning
    case error
}
