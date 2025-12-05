import Combine
import Foundation
import Frida
import SwiftData

@MainActor
final class ProcessNode: ObservableObject, Identifiable {
    let id = UUID()

    let device: Device
    let process: ProcessDetails
    let session: Session
    let script: Script

    let sessionRecord: ProcessSession

    var loadedPackageNames = Set<String>()

    @Published var instruments: [InstrumentRuntime] = []

    private let modelContext: ModelContext

    var onDestroyed: ((ProcessNode, SessionDetachReason) -> Void)?
    var eventSink: ((RuntimeEvent) -> Void)?

    init(
        device: Device,
        process: ProcessDetails,
        session: Session,
        script: Script,
        sessionRecord: ProcessSession,
        modelContext: ModelContext
    ) {
        self.device = device
        self.process = process
        self.session = session
        self.script = script
        self.sessionRecord = sessionRecord

        self.modelContext = modelContext

        self.instruments = sessionRecord.instruments.map {
            InstrumentRuntime(instance: $0, processNode: self)
        }

        startObservingSessionState()
        startObservingScriptMessages()
    }

    func stop() {
        Task { @MainActor in
            for runtime in self.instruments {
                await runtime.dispose()
            }

            try? await session.detach()
        }
    }

    private func startObservingSessionState() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for await event in self.session.events {
                switch event {
                case .detached(let reason, _):
                    self.onDestroyed?(self, reason)
                }
            }
        }
    }

    private func startObservingScriptMessages() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for await event in self.script.events {
                switch event {
                case .message(let message, let data):
                    if !tryHandleMessage(message, data: data) {
                        let evt = RuntimeEvent(
                            source: .repl(process: self),
                            payload: message,
                            data: data.map { Array($0) }
                        )
                        self.eventSink?(evt)
                    }

                case .destroyed:
                    break
                }
            }
        }
    }

    func tryHandleMessage(_ message: Any, data: [UInt8]?) -> Bool {
        guard let envelope = message as? [String: Any],
            let envelopeType = envelope["type"] as? String
        else {
            return false
        }

        switch envelopeType {

        case "send":
            guard let inner = envelope["payload"],
                let dict = inner as? [String: Any],
                let type = dict["type"] as? String
            else {
                return false
            }

            switch type {

            case "console":
                guard let levelString = dict["level"] as? String,
                    let level = ConsoleLevel(rawValue: levelString),
                    let encodedArgs = dict["args"] as? [Any]
                else {
                    return false
                }

                var values: [JSInspectValue] = []
                for encoded in encodedArgs {
                    guard let value = try? JSInspectValue.decodePacked(tree: encoded, blobBytes: data) else {
                        return false
                    }
                    values.append(value)
                }

                let consoleMessage = ConsoleMessage(level: level, values: values)

                let evt = RuntimeEvent(
                    source: .console(process: self),
                    payload: consoleMessage,
                    data: data.map { Array($0) }
                )
                self.eventSink?(evt)
                return true

            case "instrument-event":
                guard let instanceId = dict["instance_id"] as? String,
                    let instrumentRuntime = self.instruments.first(where: { $0.id.uuidString == instanceId }),
                    let encodedPayload = dict["payload"]
                else {
                    return false
                }

                guard let payload = try? JSInspectValue.decodePacked(tree: encodedPayload, blobBytes: data) else {
                    return false
                }

                let evt = RuntimeEvent(
                    source: .instrument(process: self, instrument: instrumentRuntime),
                    payload: payload,
                    data: data.map { Array($0) }
                )
                self.eventSink?(evt)
                return true

            default:
                return false
            }

        case "error":
            guard let text = envelope["description"] as? String else {
                return false
            }
            let fileName = envelope["fileName"] as? String
            let lineNumber = envelope["lineNumber"] as? Int
            let columnNumber = envelope["columnNumber"] as? Int
            let stack = envelope["stack"] as? String

            let error = JSError(
                text: text,
                fileName: fileName,
                lineNumber: lineNumber,
                columnNumber: columnNumber,
                stack: stack
            )

            let evt = RuntimeEvent(
                source: .script(process: self),
                payload: error,
                data: data.map { Array($0) }
            )
            self.eventSink?(evt)
            return true

        default:
            return false
        }
    }

    func evalInREPL(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (jsCode, pipeline) = splitCodeAndPipeline(trimmed)

        do {
            let anyResult = try await self.script.exports.evaluate(jsCode, ["raw": pipeline != nil])

            if let pipeline {
                try await handlePipelineResult(anyResult, originalCode: trimmed, pipeline: pipeline)
                return
            }

            guard let jsValue = try? JSInspectValue.decodePacked(from: anyResult) else {
                return
            }

            append(
                REPLCell(
                    code: trimmed,
                    result: .js(jsValue),
                    timestamp: Date()
                ))
        } catch {
            append(
                REPLCell(
                    code: trimmed,
                    result: .text("Error: \(error)"),
                    timestamp: Date()
                ))
        }
    }

    private func splitCodeAndPipeline(_ code: String) -> (jsCode: String, pipeline: String?) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = trimmed.range(of: "|>") {
            let jsPart = trimmed[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pipePart = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !jsPart.isEmpty, !pipePart.isEmpty {
                return (jsPart, pipePart)
            }
        }

        return (trimmed, nil)
    }

    private func handlePipelineResult(
        _ anyResult: Any?,
        originalCode: String,
        pipeline: String
    ) async throws {
        if let dict = anyResult as? JSONObject,
            let kind = dict["kind"] as? String,
            kind == "error"
        {
            let text = (dict["text"] as? String) ?? "Unknown error"
            append(
                REPLCell(
                    code: originalCode,
                    result: .text(text),
                    timestamp: Date()
                ))
            return
        }

        if let pair = anyResult as? [Any], pair.count == 2, let bytes = pair[1] as? [UInt8] {
            let data = Data(bytes)
            let outputData = try await runPipeline(pipeline, input: data)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"

            append(
                REPLCell(
                    code: originalCode,
                    result: .text(outputString),
                    timestamp: Date()
                ))
            return
        }

        if let bytes = anyResult as? [UInt8] {
            let data = Data(bytes)
            let outputData = try await runPipeline(pipeline, input: data)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"

            append(
                REPLCell(
                    code: originalCode,
                    result: .text(outputString),
                    timestamp: Date()
                ))
            return
        }

        if let value = anyResult,
            JSONSerialization.isValidJSONObject(value),
            let inputData = try? JSONSerialization.data(withJSONObject: value)
        {

            let outputData = try await runPipeline(pipeline, input: inputData)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"

            append(
                REPLCell(
                    code: originalCode,
                    result: .text(outputString),
                    timestamp: Date()
                ))
            return
        }

        let s = anyResult.map { String(describing: $0) } ?? "null"
        append(
            REPLCell(
                code: originalCode,
                result: .text(s),
                timestamp: Date()
            ))
    }

    private func runPipeline(_ command: String, input: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-lc", command]

                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()

                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    stdinPipe.fileHandleForWriting.write(input)
                    stdinPipe.fileHandleForWriting.closeFile()

                    process.waitUntilExit()

                    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus != 0 {
                        let stderrText = String(data: err, encoding: .utf8) ?? ""
                        let error = NSError(
                            domain: "REPLPipeline",
                            code: Int(process.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey: "Pipeline “\(command)” failed with status \(process.terminationStatus)",
                                "stderr": stderrText,
                            ]
                        )
                        continuation.resume(throwing: error)
                        return
                    }

                    continuation.resume(returning: out)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func completeInREPL(code: String, cursor: Int) async -> [String] {
        do {
            let anyResult = try await script.exports.complete(code, cursor)

            if let strings = anyResult as? [String] {
                return strings
            }

            if let anyArray = anyResult as? [Any] {
                return anyArray.compactMap { $0 as? String }
            }
        } catch {
            print("REPL completion RPC failed: \(error)")
        }

        return []
    }

    private func append(_ cell: REPLCell) {
        cell.session = sessionRecord
        modelContext.insert(cell)
    }

    func markSessionBoundary() {
        append(
            REPLCell(
                code: "New process attached",
                result: .text(""),
                timestamp: Date(),
                isSessionBoundary: true
            ))
    }
}
