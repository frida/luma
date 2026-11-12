import Foundation

extension Engine {
    public func transcript(of events: [RuntimeEvent]) -> String {
        events.map(transcriptEntry).joined(separator: "\n")
    }

    private func transcriptEntry(for event: RuntimeEvent) -> String {
        let header = "\(transcriptTimestampFormatter.string(from: event.timestamp))  [\(sourceLabel(for: event))]"
        let body = transcriptBody(for: event)
        if body.contains("\n") {
            let indentedBody = body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    \($0)" }
                .joined(separator: "\n")
            return "\(header)\n\(indentedBody)"
        }
        return "\(header) \(body)"
    }

    public func sourceLabel(for event: RuntimeEvent) -> String {
        let process = session(id: event.sessionID ?? UUID())?.processName ?? ""
        switch event.source {
        case .processOutput(let fd):
            let channel: String
            switch fd {
            case 1: channel = "stdout"
            case 2: channel = "stderr"
            default: channel = "fd\(fd)"
            }
            return "\(process) • \(channel)"
        case .script:
            return "\(process) • Script Runtime"
        case .console:
            return "\(process) • Console"
        case .repl:
            return "\(process) • REPL"
        case .instrument:
            let name = instrument(forEvent: event).map { descriptor(for: $0).displayName } ?? "Instrument"
            return "\(name) • \(process)"
        case .spawnGating(_, let deviceName, _, _, let outcome):
            let label = outcome == .captured ? "Spawn Captured" : "Spawn Released"
            return "\(deviceName) • \(label)"
        case .engine(let subsystem):
            return "Engine • \(subsystem)"
        }
    }

    private func transcriptBody(for event: RuntimeEvent) -> String {
        switch event.payload {
        case .consoleMessage(let message):
            return "\(message.level.rawValue.uppercased()) \(transcriptText(ofArguments: message.values))"
        case .jsError(let error):
            return [error.text, error.stack].compactMap { $0 }.joined(separator: "\n")
        case .jsValue(let value):
            if case .instrument = event.source,
                let tracerEvent = Engine.parseTracerEvent(from: value),
                case .array(_, let arguments) = tracerEvent.message
            {
                return transcriptText(ofArguments: arguments)
            }
            return transcriptText(ofArguments: [value])
        case .raw(let message, _):
            return String(describing: message)
        }
    }

    private func transcriptText(ofArguments arguments: [JSInspectValue]) -> String {
        arguments.map { argument in
            if case .string(let text) = argument { return text }
            return argument.prettyDescription(bytes: .hexDump)
        }.joined(separator: " ")
    }
}

private let transcriptTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
}()
