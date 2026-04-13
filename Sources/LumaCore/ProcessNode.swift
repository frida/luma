import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class ProcessNode: Identifiable {
    public let id = UUID()

    public let device: Device
    public let process: ProcessDetails
    public let session: Session
    public let script: Script

    public private(set) var modules: [ProcessModule] = []

    public struct InstrumentRef: Sendable {
        public let id: UUID
        public let kind: InstrumentKind
        public let sourceIdentifier: String
        public var configJSON: Data
        public var isEnabled: Bool
        public var isAttached: Bool

        public init(id: UUID, kind: InstrumentKind, sourceIdentifier: String, configJSON: Data, isEnabled: Bool = true, isAttached: Bool = false) {
            self.id = id
            self.kind = kind
            self.sourceIdentifier = sourceIdentifier
            self.configJSON = configJSON
            self.isEnabled = isEnabled
            self.isAttached = isAttached
        }
    }

    public private(set) var instruments: [InstrumentRef] = []

    public var loadedPackageNames = Set<String>()

    private let _events = AsyncEventSource<RuntimeEvent>()
    private let _replResults = AsyncEventSource<REPLResult>()
    private let _captures = AsyncEventSource<CapturedITrace>()
    private let _moduleSnapshots = AsyncEventSource<[ProcessModule]>()
    private let _detachEvents = AsyncEventSource<SessionDetachReason>()

    public var events: AsyncStream<RuntimeEvent> { _events.makeStream() }
    public var replResults: AsyncStream<REPLResult> { _replResults.makeStream() }
    public var captures: AsyncStream<CapturedITrace> { _captures.makeStream() }
    public var moduleSnapshots: AsyncStream<[ProcessModule]> { _moduleSnapshots.makeStream() }
    public var detachEvents: AsyncStream<SessionDetachReason> { _detachEvents.makeStream() }

    private var scriptEventsStarted = false
    private var scriptEventsStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var moduleSnapshotState: ModuleSnapshotState = .pending
    private var moduleSnapshotWaiters: [CheckedContinuation<Void, Swift.Error>] = []

    private enum ModuleSnapshotState: Equatable {
        case pending
        case ready
        case detached
    }

    private var systemSession: Session?
    private var drainScript: Script?
    private var drainTimer: Task<Void, Never>?
    private var pendingCaptures: [String: PendingITraceCapture] = [:]

    private let drainAgentSource: String?

    struct PendingITraceCapture {
        let hookID: UUID
        let callIndex: Int
        var hookTarget: String?
        var prologueBytes: String?
        var chunks: [Data]
        var metadataJSON: Data?
        var lost: Int
        var useSystemDrain: Bool
    }

    public init(
        device: Device,
        process: ProcessDetails,
        session: Session,
        script: Script,
        instruments: [InstrumentRef] = [],
        drainAgentSource: String? = nil
    ) {
        self.device = device
        self.process = process
        self.session = session
        self.script = script
        self.instruments = instruments
        self.drainAgentSource = drainAgentSource

        startObservingSessionState()
        startObservingScriptMessages()
    }

    public func stop() {
        Task { @MainActor in
            for instrument in instruments where instrument.isAttached {
                _ = try? await script.exports.disposeInstrument(["instanceId": instrument.id.uuidString])
            }
            await tearDownITrace()
            try? await session.detach()
        }
    }

    // MARK: - Session & Script Observation

    private func startObservingSessionState() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for await event in self.session.events {
                switch event {
                case .detached(let reason, _):
                    await self.finalizePendingCapturesOnCrash()
                    self.failInitialModulesSnapshotWaitersIfNeeded()
                    self._detachEvents.yield(reason)
                    self._events.finish()
                    self._replResults.finish()
                    self._captures.finish()
                    self._moduleSnapshots.finish()
                    self._detachEvents.finish()
                }
            }
        }
    }

    private func startObservingScriptMessages() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.scriptEventsStarted = true
            let waiters = self.scriptEventsStartWaiters
            self.scriptEventsStartWaiters.removeAll(keepingCapacity: false)
            for w in waiters { w.resume() }

            for await event in self.script.events {
                switch event {
                case .message(let message, let data):
                    if !self.tryHandleMessage(message, data: data) {
                        self._events.yield(RuntimeEvent(
                            source: .repl,
                            payload: .raw(message: message, data: data)
                        ))
                    }

                case .destroyed:
                    break
                }
            }
        }
    }

    public func waitForScriptEventsSubscription() async {
        if scriptEventsStarted { return }

        await withCheckedContinuation { cont in
            if scriptEventsStarted {
                cont.resume()
            } else {
                scriptEventsStartWaiters.append(cont)
            }
        }
    }

    // MARK: - Message Dispatch

    public func tryHandleMessage(_ message: Any, data: [UInt8]?) -> Bool {
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

            case "modules-changed":
                let addedDicts = (dict["added"] as? [[String: Any]]) ?? []
                let removedDicts = (dict["removed"] as? [[String: Any]]) ?? []

                let added = addedDicts.compactMap { Self.decodeModuleDTO($0) }
                let removed = removedDicts.compactMap { Self.decodeModuleDTO($0) }

                if !removed.isEmpty {
                    let removedBases = Set(removed.map { $0.base })
                    modules.removeAll { removedBases.contains($0.base) }
                }

                modules.append(contentsOf: added)
                markInitialModulesSnapshotReadyIfNeeded()

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

                _events.yield(RuntimeEvent(
                    source: .console,
                    payload: .consoleMessage(ConsoleMessage(level: level, values: values)),
                    data: data.map { Array($0) }
                ))

                return true

            case "itrace:start":
                if let hookId = dict["hookId"] as? String,
                    let callIndex = dict["callIndex"] as? Int,
                    let bufferLocation = dict["bufferLocation"] as? String
                {
                    let hookTarget = dict["hookTarget"] as? String
                    let prologueBytes = dict["prologueBytes"] as? String
                    Task { @MainActor in
                        await self.handleITraceStart(
                            hookId: hookId, callIndex: callIndex,
                            bufferLocation: bufferLocation,
                            hookTarget: hookTarget,
                            prologueBytes: prologueBytes)
                    }
                }
                return true

            case "itrace:stop":
                if let hookId = dict["hookId"] as? String,
                    let callIndex = dict["callIndex"] as? Int
                {
                    let lost = dict["lost"] as? Int ?? 0
                    Task { @MainActor in
                        await self.handleITraceStop(
                            hookId: hookId, callIndex: callIndex,
                            lost: lost, data: data)
                    }
                }
                return true

            case "itrace:chunk":
                if let hookId = dict["hookId"] as? String,
                    let callIndex = dict["callIndex"] as? Int,
                    let chunkData = data
                {
                    let lost = dict["lost"] as? Int ?? 0
                    handleITraceChunk(
                        hookId: hookId, callIndex: callIndex,
                        data: Array(chunkData), lost: lost)
                }
                return true

            case "instrument-event":
                guard let instanceId = dict["instance_id"] as? String,
                    let instrumentID = UUID(uuidString: instanceId),
                    let instrument = instruments.first(where: { $0.id == instrumentID }),
                    let encodedPayload = dict["payload"]
                else {
                    return false
                }

                guard let payload = try? JSInspectValue.decodePacked(tree: encodedPayload, blobBytes: data) else {
                    return false
                }

                _events.yield(RuntimeEvent(
                    source: .instrument(id: instrument.id, name: instrument.sourceIdentifier),
                    payload: .jsValue(payload),
                    data: data.map { Array($0) }
                ))

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

            _events.yield(RuntimeEvent(
                source: .script,
                payload: .jsError(JSError(
                    text: text,
                    fileName: fileName,
                    lineNumber: lineNumber,
                    columnNumber: columnNumber,
                    stack: stack
                ))
            ))
            return true

        default:
            return false
        }
    }

    // MARK: - Module Snapshots

    private func markInitialModulesSnapshotReadyIfNeeded() {
        guard moduleSnapshotState == .pending else { return }
        moduleSnapshotState = .ready

        _moduleSnapshots.yield(modules)

        let waiters = moduleSnapshotWaiters
        moduleSnapshotWaiters.removeAll(keepingCapacity: false)
        for w in waiters { w.resume() }
    }

    private func failInitialModulesSnapshotWaitersIfNeeded() {
        guard moduleSnapshotState == .pending else { return }
        moduleSnapshotState = .detached

        let waiters = moduleSnapshotWaiters
        moduleSnapshotWaiters.removeAll(keepingCapacity: false)
        for w in waiters {
            w.resume(throwing: LumaCoreError.invalidOperation("Session detached"))
        }
    }

    public func waitForInitialModulesSnapshot() async throws {
        switch moduleSnapshotState {
        case .ready:
            return
        case .detached:
            throw LumaCoreError.invalidOperation("Session detached")
        case .pending:
            break
        }

        try await withCheckedThrowingContinuation { cont in
            switch moduleSnapshotState {
            case .ready:
                cont.resume()
            case .detached:
                cont.resume(throwing: LumaCoreError.invalidOperation("Session detached"))
            case .pending:
                moduleSnapshotWaiters.append(cont)
            }
        }
    }

    // MARK: - REPL

    public func evalInREPL(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (jsCode, pipeline) = splitCodeAndPipeline(trimmed)

        do {
            let anyResult = try await script.exports.evaluate(jsCode, ["raw": pipeline != nil])

            if let pipeline {
                try await handlePipelineResult(anyResult, originalCode: trimmed, pipeline: pipeline)
                return
            }

            guard let jsValue = try? JSInspectValue.decodePacked(from: anyResult) else {
                return
            }

            _replResults.yield(REPLResult(code: trimmed, value: .js(jsValue)))
        } catch {
            _replResults.yield(REPLResult(code: trimmed, value: .text("Error: \(error)")))
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
            _replResults.yield(REPLResult(code: originalCode, value: .text(text)))
            return
        }

        if let pair = anyResult as? [Any], pair.count == 2, let bytes = pair[1] as? [UInt8] {
            let data = Data(bytes)
            let outputData = try await runPipeline(pipeline, input: data)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"
            _replResults.yield(REPLResult(code: originalCode, value: .text(outputString)))
            return
        }

        if let bytes = anyResult as? [UInt8] {
            let data = Data(bytes)
            let outputData = try await runPipeline(pipeline, input: data)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"
            _replResults.yield(REPLResult(code: originalCode, value: .text(outputString)))
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
            _replResults.yield(REPLResult(code: originalCode, value: .text(outputString)))
            return
        }

        let s = anyResult.map { String(describing: $0) } ?? "null"
        _replResults.yield(REPLResult(code: originalCode, value: .text(s)))
    }

    private func runPipeline(_ command: String, input: Data) async throws -> Data {
        #if os(macOS) || os(Linux)
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
                                NSLocalizedDescriptionKey:
                                    "Pipeline \"\(command)\" failed with status \(process.terminationStatus)",
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
        #else
        throw LumaCoreError.notSupported("Running shell pipelines is only supported on macOS and Linux")
        #endif
    }

    public func completeInREPL(code: String, cursor: Int) async -> [String] {
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

    // MARK: - Memory & Symbolication

    public func readRemoteMemory(at address: UInt64, count: Int) async throws -> [UInt8] {
        let addr = String(format: "0x%llx", address)
        let any = try await script.exports.readMemory(addr, count)
        guard let bytes = any as? [UInt8] else {
            throw LumaCoreError.protocolViolation("Invalid reply")
        }
        return bytes
    }

    public func anchor(for address: UInt64) -> AddressAnchor {
        if let m = modules.first(where: { address >= $0.base && address < ($0.base + $0.size) }) {
            return .moduleOffset(name: m.name, offset: address - m.base)
        }
        return .absolute(address)
    }

    public func resolve(_ anchor: AddressAnchor) async throws -> UInt64 {
        try await waitForInitialModulesSnapshot()

        switch anchor {
        case .absolute(let a):
            return a

        case .moduleOffset(let name, let offset):
            guard let m = modules.first(where: { $0.name == name }) else {
                throw LumaCoreError.invalidArgument("Module '\(name)' not loaded in the current process")
            }
            return m.base &+ offset

        case .moduleExport(let name, let export):
            guard modules.first(where: { $0.name == name }) != nil else {
                throw LumaCoreError.invalidArgument("Module '\(name)' not loaded in the current process")
            }

            let raw = try await script.exports.lookupModuleExportAddress(name, export)

            guard let rawString = raw as? String else {
                throw LumaCoreError.invalidArgument("Invalid return type from lookupModuleExportAddress")
            }

            return try parseAgentHexAddress(rawString)
        }
    }

    public func resolveSyncIfReady(_ anchor: AddressAnchor) throws -> UInt64 {
        guard moduleSnapshotState == .ready else {
            if moduleSnapshotState == .detached {
                throw LumaCoreError.invalidOperation("Session detached")
            }
            throw LumaCoreError.invalidOperation("Initial modules snapshot not ready")
        }

        switch anchor {
        case .absolute(let a):
            return a

        case .moduleOffset(let name, let offset):
            guard let m = modules.first(where: { $0.name == name }) else {
                throw LumaCoreError.invalidArgument("Module '\(name)' not loaded")
            }
            return m.base &+ offset

        case .moduleExport:
            throw LumaCoreError.invalidOperation("moduleExport requires async resolution")
        }
    }

    public func symbolicate(addresses: [UInt64]) async throws -> [SymbolicateResult] {
        let any = try await script.exports.symbolicate(addresses.map { String(format: "0x%llx", $0) })

        guard let arr = any as? [Any],
            arr.count == addresses.count
        else {
            throw LumaCoreError.protocolViolation("Invalid reply")
        }

        var out: [SymbolicateResult] = []
        out.reserveCapacity(arr.count)

        for entry in arr {
            if entry is NSNull {
                out.append(.failure)
                continue
            }

            guard let tuple = entry as? [Any] else {
                throw LumaCoreError.protocolViolation("Invalid reply")
            }

            switch tuple.count {
            case 2:
                guard let moduleName = tuple[0] as? String,
                    let name = tuple[1] as? String
                else {
                    throw LumaCoreError.protocolViolation("Invalid reply")
                }
                out.append(.module(moduleName: moduleName, name: name))

            case 4:
                guard let moduleName = tuple[0] as? String,
                    let name = tuple[1] as? String,
                    let fileName = tuple[2] as? String,
                    let lineNumber = tuple[3] as? Int
                else {
                    throw LumaCoreError.protocolViolation("Invalid reply")
                }
                out.append(.file(moduleName: moduleName, name: name, fileName: fileName, lineNumber: lineNumber))

            case 5:
                guard let moduleName = tuple[0] as? String,
                    let name = tuple[1] as? String,
                    let fileName = tuple[2] as? String,
                    let lineNumber = tuple[3] as? Int,
                    let column = tuple[4] as? Int
                else {
                    throw LumaCoreError.protocolViolation("Invalid reply")
                }
                out.append(.fileColumn(
                    moduleName: moduleName, name: name, fileName: fileName, lineNumber: lineNumber, column: column))

            default:
                throw LumaCoreError.protocolViolation("Invalid reply")
            }
        }

        return out
    }

    public func fetchProcessInfo() async -> ProcessInfo? {
        guard let anyInfo = try? await script.exports.getProcessInfo(),
            JSONSerialization.isValidJSONObject(anyInfo),
            let data = try? JSONSerialization.data(withJSONObject: anyInfo),
            let info = try? JSONDecoder().decode(ProcessInfo.self, from: data)
        else {
            return nil
        }
        return info
    }

    public struct ProcessInfo: Codable, Sendable {
        public let platform: String
        public let arch: String
        public let pointerSize: Int
    }

    // MARK: - Instruments

    public func addInstrument(_ ref: InstrumentRef) {
        instruments.append(ref)
    }

    public func removeInstrument(id: UUID) {
        instruments.removeAll { $0.id == id }
    }

    public func markInstrumentAttached(id: UUID) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].isAttached = true
        }
    }

    public func markInstrumentDetached(id: UUID) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].isAttached = false
        }
    }

    public func updateInstrumentConfig(id: UUID, configJSON: Data) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].configJSON = configJSON
        }
    }

    // MARK: - ITrace Orchestration

    public func setupITraceDraining() async {
        guard let drainAgentSource else { return }

        do {
            let params = try await device.querySystemParameters()
            guard (params["platform"] as? String) == "darwin",
                (params["access"] as? String) == "full"
            else {
                return
            }

            let sysSession = try await device.attach(to: 0)
            let script = try await sysSession.createScript(
                drainAgentSource,
                name: "itrace-drain",
                runtime: .v8
            )
            try await script.load()

            systemSession = sysSession
            drainScript = script
        } catch {
            // System session not available; fall back to in-process draining.
        }
    }

    public var hasSystemSession: Bool {
        drainScript != nil
    }

    func handleITraceStart(
        hookId: String, callIndex: Int, bufferLocation: String,
        hookTarget: String?, prologueBytes: String?
    ) async {
        let captureKey = Self.captureKey(hookId: hookId, callIndex: callIndex)
        pendingCaptures[captureKey] = PendingITraceCapture(
            hookID: UUID(uuidString: hookId)!,
            callIndex: callIndex,
            hookTarget: hookTarget,
            prologueBytes: prologueBytes,
            chunks: [],
            lost: 0,
            useSystemDrain: false
        )

        if let drainScript {
            do {
                try await drainScript.exports.openBuffer(bufferLocation)
                pendingCaptures[captureKey]?.useSystemDrain = true
                startDrainTimer(for: captureKey)
            } catch {
            }
        }
    }

    func handleITraceStop(hookId: String, callIndex: Int, lost: Int, data: [UInt8]?) async {
        let captureKey = Self.captureKey(hookId: hookId, callIndex: callIndex)

        let usedSystemDrain = pendingCaptures[captureKey]?.useSystemDrain == true

        if usedSystemDrain, let drainScript {
            drainTimer?.cancel()
            drainTimer = nil

            do {
                if let finalChunk = try await drainScript.exports.close() as? [UInt8], !finalChunk.isEmpty {
                    pendingCaptures[captureKey]?.chunks.append(Data(finalChunk))
                }
                let sysLost = (try? await drainScript.exports.getLost()) as? Int ?? 0
                pendingCaptures[captureKey]?.lost = sysLost
            } catch {
            }
        }

        if let data, !data.isEmpty {
            pendingCaptures[captureKey]?.chunks.append(Data(data))
        }

        let currentLost = pendingCaptures[captureKey]?.lost ?? 0
        pendingCaptures[captureKey]?.lost = max(currentLost, lost)

        await finalizeCapture(key: captureKey)
    }

    func handleITraceChunk(hookId: String, callIndex: Int, data: [UInt8], lost: Int) {
        let captureKey = Self.captureKey(hookId: hookId, callIndex: callIndex)
        pendingCaptures[captureKey]?.chunks.append(Data(data))
        pendingCaptures[captureKey]?.lost = lost
    }

    private func startDrainTimer(for captureKey: String) {
        drainTimer?.cancel()
        drainTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)

                guard let self, let drainScript = self.drainScript else { break }

                do {
                    if let chunk = try await drainScript.exports.drain() as? [UInt8], !chunk.isEmpty {
                        self.pendingCaptures[captureKey]?.chunks.append(Data(chunk))
                    }
                } catch {
                    break
                }
            }
        }
    }

    private func finalizeCapture(key captureKey: String) async {
        guard let capture = pendingCaptures.removeValue(forKey: captureKey) else {
            return
        }

        let rawData = capture.chunks.reduce(into: Data()) { $0.append($1) }

        var (traceData, metadataJSON) = ITraceDecoder.parseRawBuffer(
            rawData,
            hookTarget: capture.hookTarget,
            prologueBytes: capture.prologueBytes
        )

        ITraceDecoder.cleanupAfterCapture(traceData: &traceData, metadataJSON: &metadataJSON)

        if var metadata = try? JSONDecoder().decode(ITraceMetadata.self, from: metadataJSON) {
            let addresses = metadata.blocks.compactMap { ITraceDecoder.parseHexAddress($0.address) }
            if !addresses.isEmpty {
                var symbolicated = false
                if let results = try? await symbolicate(addresses: addresses) {
                    for (i, result) in results.enumerated() where i < metadata.blocks.count {
                        let name: String?
                        switch result {
                        case .module(let m, let n): name = "\(m)!\(n)"
                        case .file(let m, let n, _, _): name = "\(m)!\(n)"
                        case .fileColumn(let m, let n, _, _, _): name = "\(m)!\(n)"
                        case .failure: name = nil
                        }
                        if let name { metadata.blocks[i].name = name; symbolicated = true }
                    }
                }

                if !symbolicated {
                    for (i, addr) in addresses.enumerated() where i < metadata.blocks.count {
                        if let mod = modules.first(where: { addr >= $0.base && addr < $0.base + $0.size }) {
                            let offset = addr - mod.base
                            metadata.blocks[i].name = "\(mod.name)!0x\(String(offset, radix: 16))"
                        }
                    }
                }

                if let data = try? JSONEncoder().encode(metadata) {
                    metadataJSON = data
                }
            }
        }

        let hookName = instruments.lazy
            .compactMap { ref -> String? in
                guard let config = try? TracerConfig.decode(from: ref.configJSON) else { return nil }
                return config.hooks.first(where: { $0.id == capture.hookID })?.displayName
            }
            .first ?? capture.hookID.uuidString

        let displayName = "\(hookName) call #\(capture.callIndex)"

        _captures.yield(CapturedITrace(
            hookID: capture.hookID,
            callIndex: capture.callIndex,
            displayName: displayName,
            traceData: traceData,
            metadataJSON: metadataJSON,
            lost: capture.lost
        ))
    }

    private func finalizePendingCapturesOnCrash() async {
        let keys = Array(pendingCaptures.keys)
        for key in keys {
            guard var capture = pendingCaptures[key],
                !capture.chunks.isEmpty
            else {
                pendingCaptures.removeValue(forKey: key)
                continue
            }

            if capture.useSystemDrain, let drainScript {
                drainTimer?.cancel()
                drainTimer = nil
                do {
                    if let chunk = try await drainScript.exports.close() as? [UInt8], !chunk.isEmpty {
                        capture.chunks.append(Data(chunk))
                    }
                    let lost = (try? await drainScript.exports.getLost()) as? Int ?? 0
                    capture.lost = lost
                } catch {}
            }

            pendingCaptures[key] = capture
            await finalizeCapture(key: key)
        }
    }

    public func tearDownITrace() async {
        drainTimer?.cancel()
        drainTimer = nil
        pendingCaptures.removeAll()

        if let drainScript {
            try? await drainScript.unload()
            self.drainScript = nil
        }

        if let systemSession {
            try? await systemSession.detach()
            self.systemSession = nil
        }
    }

    // MARK: - Helpers

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

    private static func captureKey(hookId: String, callIndex: Int) -> String {
        "\(hookId):\(callIndex)"
    }
}
