import Combine
import Foundation
import Frida
import SwiftData
import SwiftyR2

@MainActor
final class ProcessNode: ObservableObject, Identifiable {
    let id = UUID()

    let device: Device
    let process: ProcessDetails
    let session: Session
    let script: Script

    var r2: R2Core!
    private var openR2Task: Task<Void, Never>?

    let sessionRecord: ProcessSession

    var loadedPackageNames = Set<String>()

    @Published var modules: [ProcessModule] = []
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

            case "module-added":
                guard let moduleDict = dict["module"] as? [String: Any],
                    let module = Self.decodeModuleDTO(moduleDict)
                else { return false }

                self.modules.append(module)
                self.modules.sort { $0.base < $1.base }

                return true

            case "module-removed":
                guard let moduleDict = dict["module"] as? [String: Any],
                    let module = Self.decodeModuleDTO(moduleDict)
                else { return false }

                self.modules.removeAll { $0.base == module.base }
                return true

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

    func readRemoteMemory(at address: UInt64, count: Int) async throws -> [UInt8] {
        let addr = String(format: "0x%llx", address)
        let any = try await script.exports.readMemory(addr, count)
        guard let bytes = any as? [UInt8] else {
            throw Error.protocolViolation("Invalid reply")
        }
        return bytes
    }

    func anchor(for address: UInt64) -> AddressAnchor {
        if let m = modules.first(where: { address >= $0.base && address < ($0.base + $0.size) }) {
            return .module(name: m.name, offset: address - m.base)
        }
        return .absolute(address)
    }

    func resolve(_ anchor: AddressAnchor) -> UInt64? {
        switch anchor {
        case .absolute(let a):
            return a
        case .module(let name, let offset):
            guard let m = modules.first(where: { $0.name == name }) else { return nil }
            return m.base &+ offset
        }
    }

    private static func decodeModuleDTO(_ dto: [String: Any]) -> ProcessModule? {
        guard
            let name = dto["name"] as? String,
            let path = dto["path"] as? String,
            let baseStr = dto["base"] as? String,
            let size = dto["size"] as? Int
        else { return nil }

        let base = UInt64(baseStr.dropFirst(2), radix: 16) ?? 0
        return ProcessModule(name: name, path: path, base: base, size: UInt64(size))
    }

    private func ensureR2Opened() async {
        if let task = openR2Task {
            await task.value
            return
        }

        let task = Task { @MainActor in
            let r2 = await R2Core.create()
            self.r2 = r2

            await r2.registerIOPlugin(
                asyncProvider: ProcessMemoryIOProvider(processNode: self),
                uriSchemes: ["frida-mem://"]
            )

            await r2.setColorLimit(.mode16M)

            await r2.config.set("scr.utf8", bool: true)
            await r2.config.set("scr.color", colorMode: .mode16M)
            await r2.config.set("cfg.json.num", string: "hex")
            await r2.config.set("asm.emu", bool: true)
            await r2.config.set("emu.str", bool: true)
            await r2.config.set("anal.cc", string: "cdecl")

            // FIXME: Stop hard-coding these:
            await r2.config.set("asm.os", string: "linux")
            await r2.config.set("asm.arch", string: "arm")
            await r2.config.set("asm.bits", int: 64)

            let uri = "frida-mem://0x0"
            await r2.openFile(uri: uri)
            await r2.cmd("=!")
            await r2.binLoad(uri: uri)
        }

        openR2Task = task
        await task.value
    }

    func applyR2Theme(_ name: String) async {
        await ensureR2Opened()
        await r2.applyTheme(name)
    }

    func r2Cmd(_ command: String) async -> String {
        await ensureR2Opened()
        return await r2.cmd(command)
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
