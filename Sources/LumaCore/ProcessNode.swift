import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class ProcessNode: Identifiable {
    public enum Phase: String, Sendable {
        case attaching
        case attached
        case detached
    }

    public let id = UUID()
    public let sessionID: UUID

    public let deviceID: String
    public let deviceName: String
    public let pid: UInt
    public let processName: String
    public let processIcons: [Icon]

    public internal(set) var phase: Phase
    public internal(set) var lastSeenAt: Date

    public private(set) var modules: [ProcessModule] = []
    public private(set) var threads: [ProcessThread] = []
    public private(set) var mainModule: ProcessModule?
    public private(set) var processInfo: ProcessInfo?

    private let device: Device
    private let process: ProcessDetails
    private let session: Session
    private let script: Script

    public enum AttachmentState: String, Sendable {
        case attached
        case detached
    }

    public struct InstrumentRef: Sendable {
        public let id: UUID
        public let kind: InstrumentKind
        public let sourceIdentifier: String
        public var configJSON: Data
        public var state: InstrumentState
        public var attachment: AttachmentState

        public init(
            id: UUID,
            kind: InstrumentKind,
            sourceIdentifier: String,
            configJSON: Data,
            state: InstrumentState = .enabled,
            attachment: AttachmentState = .detached
        ) {
            self.id = id
            self.kind = kind
            self.sourceIdentifier = sourceIdentifier
            self.configJSON = configJSON
            self.state = state
            self.attachment = attachment
        }
    }

    public private(set) var instruments: [InstrumentRef] = []

    public var loadedPackageNames = Set<String>()

    private let _events = AsyncEventSource<RuntimeEvent>()
    private let _replResults = AsyncEventSource<REPLResult>()
    private let _traceUpdates = AsyncEventSource<ITrace>()
    private let _moduleDeltas = AsyncEventSource<ModuleDelta>()
    private let _threadDeltas = AsyncEventSource<ThreadDelta>()
    private let _detachEvents = AsyncEventSource<SessionDetachReason>()
    private let _widgetUpdates = AsyncEventSource<WidgetUpdate>()

    public var events: AsyncStream<RuntimeEvent> { _events.makeStream() }
    public var replResults: AsyncStream<REPLResult> { _replResults.makeStream() }
    public var traceUpdates: AsyncStream<ITrace> { _traceUpdates.makeStream() }
    public var moduleDeltas: AsyncStream<ModuleDelta> { _moduleDeltas.makeStream() }
    public var threadDeltas: AsyncStream<ThreadDelta> { _threadDeltas.makeStream() }
    public var detachEvents: AsyncStream<SessionDetachReason> { _detachEvents.makeStream() }
    public var widgetUpdates: AsyncStream<WidgetUpdate> { _widgetUpdates.makeStream() }

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
    private var systemDrainOwner: String?
    private var pendingTraces: [String: PendingTrace] = [:]
    private var pendingEmits: [String: Task<Void, Never>] = [:]
    private var inProcessDrainTasks: [String: Task<Void, Never>] = [:]
    private static let runningTraceEmitInterval: UInt64 = 250_000_000
    private static let inProcessDrainInterval: UInt64 = 50_000_000

    private let drainAgentSource: String?
    private let traceStore: TraceStore?

    struct PendingTrace {
        let id: UUID
        let origin: ITrace.Origin
        let displayName: String
        let startedAt: Date
        var hookTarget: String?
        var prologueBytes: String?
        var accumulated: Data
        var lost: Int
        var useSystemDrain: Bool
    }

    public init(
        sessionID: UUID,
        device: Device,
        process: ProcessDetails,
        session: Session,
        script: Script,
        instruments: [InstrumentRef] = [],
        drainAgentSource: String? = nil,
        traceStore: TraceStore? = nil
    ) {
        self.sessionID = sessionID
        self.device = device
        self.process = process
        self.session = session
        self.script = script
        self.deviceID = device.id
        self.deviceName = device.name
        self.pid = process.pid
        self.processName = process.name
        self.processIcons = process.icons
        self.phase = .attached
        self.lastSeenAt = Date()
        self.instruments = instruments
        self.drainAgentSource = drainAgentSource
        self.traceStore = traceStore

        startObservingSessionState()
        startObservingScriptMessages()
    }

    public func stop() {
        Task { @MainActor in
            for instrument in instruments where instrument.attachment == .attached {
                _ = try? await script.exports.disposeInstrument(["instanceId": instrument.id.uuidString])
            }
            await tearDownITrace()
            try? await session.detach()
        }
    }

    public func kill() async throws {
        try await device.kill(pid)
    }

    public func resume() async throws {
        try await device.resume(pid)
    }

    public func loadPackages(_ bundles: [Any]) async throws {
        try await script.exports.loadPackages(JSValue(bundles))
    }

    // MARK: - Session & Script Observation

    private func startObservingSessionState() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for await event in session.events {
                switch event {
                case .detached(let reason, _):
                    await self.finalizePendingTracesOnCrash()
                    self.failInitialModulesSnapshotWaitersIfNeeded()
                    self._detachEvents.yield(reason)
                    self._events.finish()
                    self._replResults.finish()
                    self._traceUpdates.finish()
                    self._moduleDeltas.finish()
                    self._threadDeltas.finish()
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

            for await event in script.events {
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

                let added = addedDicts.compactMap(ProcessModule.fromJSON)
                let removed = removedDicts.compactMap(ProcessModule.fromJSON)

                if !removed.isEmpty {
                    let removedBases = Set(removed.map { $0.base })
                    modules.removeAll { removedBases.contains($0.base) }
                }

                modules.append(contentsOf: added)
                markInitialModulesReadyIfNeeded()

                _moduleDeltas.yield(ModuleDelta(added: added, removed: removed))

                return true

            case "threads-changed":
                let addedDicts = (dict["added"] as? [[String: Any]]) ?? []
                let removedIDs = (dict["removed"] as? [Int]) ?? []
                let renamedDicts = (dict["renamed"] as? [[String: Any]]) ?? []

                let addedThreads = addedDicts.compactMap(ProcessThread.fromJSON)

                let removedSet = Set(removedIDs.map { UInt($0) })
                if !removedSet.isEmpty {
                    threads.removeAll { removedSet.contains($0.id) }
                }

                threads.append(contentsOf: addedThreads)

                var renames: [ThreadDelta.Rename] = []
                for entry in renamedDicts {
                    guard let rawID = entry["id"] as? Int else { continue }
                    let tid = UInt(rawID)
                    let newName = entry["name"] as? String
                    if let i = threads.firstIndex(where: { $0.id == tid }) {
                        threads[i].name = newName
                    }
                    renames.append(ThreadDelta.Rename(id: tid, name: newName))
                }

                _threadDeltas.yield(ThreadDelta(
                    added: addedThreads,
                    removed: Array(removedSet),
                    renamed: renames
                ))

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
                guard let sessionId = dict["sessionId"] as? String,
                    let bufferLocation = dict["bufferLocation"] as? String,
                    let originDict = dict["origin"] as? [String: Any],
                    let origin = parseTraceOrigin(originDict)
                else { return false }

                let hookTarget = dict["hookTarget"] as? String
                let prologueBytes = dict["prologueBytes"] as? String
                Task { @MainActor in
                    await self.handleITraceStart(
                        sessionId: sessionId,
                        origin: origin,
                        bufferLocation: bufferLocation,
                        hookTarget: hookTarget,
                        prologueBytes: prologueBytes)
                }
                return true

            case "itrace:stop":
                guard let sessionId = dict["sessionId"] as? String else { return false }
                let lost = dict["lost"] as? Int ?? 0
                Task { @MainActor in
                    await self.handleITraceStop(sessionId: sessionId, lost: lost, data: data)
                }
                return true

            case "itrace:chunk":
                guard let sessionId = dict["sessionId"] as? String,
                    let chunkData = data
                else { return false }
                let lost = dict["lost"] as? Int ?? 0
                handleITraceChunk(sessionId: sessionId, data: Array(chunkData), lost: lost)
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

            case "widget-graph-point":
                guard let update = decodeGraphPointUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-list-upsert":
                guard let update = decodeListUpsertUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-list-remove":
                guard let update = decodeListRemoveUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-clear":
                guard let update = decodeClearUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
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

    // MARK: - Widget Updates

    private func decodeGraphPointUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let pointObj = dict["point"] as? [String: Any],
            let series = pointObj["series"] as? String,
            let x = decodeNumber(pointObj["x"]),
            let y = decodeNumber(pointObj["y"])
        else { return nil }
        let point = WidgetGraphPoint(series: series, x: x, y: y)
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .graphPoint(point))
    }

    private func decodeListUpsertUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let itemObj = dict["item"] as? [String: Any],
            let id = itemObj["id"] as? String,
            let title = itemObj["title"] as? String
        else { return nil }
        let item = WidgetListItem(
            id: id,
            title: title,
            subtitle: itemObj["subtitle"] as? String,
            accessory: itemObj["accessory"] as? String
        )
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .listUpsert(item))
    }

    private func decodeListRemoveUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let itemID = dict["item"] as? String
        else { return nil }
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .listRemove(itemID: itemID))
    }

    private func decodeClearUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict) else { return nil }
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .clear)
    }

    private func decodeWidgetContext(_ dict: [String: Any]) -> (instanceID: UUID, widget: String)? {
        guard let instanceId = dict["instance_id"] as? String,
            let instanceID = UUID(uuidString: instanceId),
            let widget = dict["widget"] as? String
        else { return nil }
        return (instanceID, widget)
    }

    private func decodeNumber(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Module Snapshots

    private func markInitialModulesReadyIfNeeded() {
        guard moduleSnapshotState == .pending else { return }
        moduleSnapshotState = .ready

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

    public func evalInREPL(_ code: String, cellID: UUID = UUID()) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (jsCode, pipeline) = splitCodeAndPipeline(trimmed)

        do {
            let anyResult = try await script.exports.evaluate(jsCode, ["raw": pipeline != nil])

            if let pipeline {
                try await handlePipelineResult(anyResult, cellID: cellID, originalCode: trimmed, pipeline: pipeline)
                return
            }

            guard let jsValue = try? JSInspectValue.decodePacked(from: anyResult) else {
                return
            }

            _replResults.yield(REPLResult(id: cellID, code: trimmed, value: .js(jsValue)))
        } catch {
            _replResults.yield(REPLResult(id: cellID, code: trimmed, value: .text("Error: \(error)")))
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
        cellID: UUID,
        originalCode: String,
        pipeline: String
    ) async throws {
        if let dict = anyResult as? JSONObject,
            let kind = dict["kind"] as? String,
            kind == "error"
        {
            let text = (dict["text"] as? String) ?? "Unknown error"
            _replResults.yield(REPLResult(id: cellID, code: originalCode, value: .text(text)))
            return
        }

        if let pair = anyResult as? [Any], pair.count == 2, let bytes = pair[1] as? [UInt8] {
            let data = Data(bytes)
            let outputData = try await runPipeline(pipeline, input: data)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"
            _replResults.yield(REPLResult(id: cellID, code: originalCode, value: .text(outputString)))
            return
        }

        if let bytes = anyResult as? [UInt8] {
            let data = Data(bytes)
            let outputData = try await runPipeline(pipeline, input: data)
            let outputString =
                String(data: outputData, encoding: .utf8)
                ?? "(\(outputData.count) bytes from pipeline)"
            _replResults.yield(REPLResult(id: cellID, code: originalCode, value: .text(outputString)))
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
            _replResults.yield(REPLResult(id: cellID, code: originalCode, value: .text(outputString)))
            return
        }

        let s = anyResult.map { String(describing: $0) } ?? "null"
        _replResults.yield(REPLResult(id: cellID, code: originalCode, value: .text(s)))
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

        case .moduleExport(let name, _):
            guard modules.first(where: { $0.name == name }) != nil else {
                throw LumaCoreError.invalidArgument("Module '\(name)' not loaded in the current process")
            }
            return try await lookupAnchor(anchor)

        case .objcMethod, .swiftFunc, .debugSymbol:
            return try await lookupAnchor(anchor)

        case .javaMethod:
            throw LumaCoreError.invalidOperation("\(anchor.displayString) is a Java method and has no native address")
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

        case .moduleExport, .objcMethod, .swiftFunc, .debugSymbol:
            throw LumaCoreError.invalidOperation("\(anchor.displayString) requires async resolution")

        case .javaMethod:
            throw LumaCoreError.invalidOperation("\(anchor.displayString) is a Java method and has no native address")
        }
    }

    private func lookupAnchor(_ anchor: AddressAnchor) async throws -> UInt64 {
        let raw = try await script.exports.lookupAnchorAddress(anchor.toJSON())
        guard let rawString = raw as? String else {
            throw LumaCoreError.invalidArgument("Could not resolve \(anchor.displayString)")
        }
        return try parseAgentHexAddress(rawString)
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

    public func fetchThreadSnapshot(id: UInt) async throws -> ThreadSnapshot? {
        let raw = try await script.exports.getThreadSnapshot(Int(id))
        if raw is NSNull { return nil }
        guard let dict = raw as? [String: Any] else {
            throw LumaCoreError.protocolViolation("getThreadSnapshot: unexpected response shape")
        }
        return ThreadSnapshot.fromJSON(dict)
    }

    public func enumerateModuleSymbols(name: String) async throws -> ModuleSymbolBundle {
        let raw = try await script.exports.enumerateModuleSymbols(name)
        guard let dict = raw as? [String: Any] else {
            throw LumaCoreError.protocolViolation("enumerateModuleSymbols: unexpected response shape")
        }
        return ModuleSymbolBundle.fromJSON(dict)
    }

    public func resolveTargets(scope: String, query: String) async throws -> [[String: Any]] {
        let raw = try await script.exports.resolveTargets([
            "scope": scope,
            "query": query,
        ])
        guard let arr = raw as? [[String: Any]] else {
            throw LumaCoreError.protocolViolation("resolveTargets: unexpected response shape")
        }
        return arr
    }

    public func fetchProcessInfo() async -> ProcessInfo? {
        guard let anyInfo = try? await script.exports.getProcessInfo(),
            JSONSerialization.isValidJSONObject(anyInfo),
            let data = try? JSONSerialization.data(withJSONObject: anyInfo),
            let info = try? JSONDecoder().decode(ProcessInfo.self, from: data)
        else {
            return nil
        }
        processInfo = info
        mainModule = ProcessModule(
            name: info.mainModule.name,
            path: info.mainModule.path,
            base: info.mainModule.parsedBase,
            size: UInt64(info.mainModule.size)
        )
        return info
    }

    public struct ProcessInfo: Codable, Sendable {
        public let platform: String
        public let arch: String
        public let pointerSize: Int
        public let mainModule: MainModule

        public struct MainModule: Codable, Sendable {
            public let name: String
            public let path: String
            public let base: String
            public let size: Int

            var parsedBase: UInt64 {
                let trimmed = base.hasPrefix("0x") ? String(base.dropFirst(2)) : base
                return UInt64(trimmed, radix: 16) ?? 0
            }
        }
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
            instruments[i].attachment = .attached
        }
    }

    public func markInstrumentDetached(id: UUID) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].attachment = .detached
        }
    }

    public func updateInstrumentConfig(id: UUID, configJSON: Data) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].configJSON = configJSON
        }
    }

    public func loadInstrumentOnAgent(
        instanceID: UUID,
        moduleName: String,
        source: String,
        config: Any,
        restored: [String: Any] = [:]
    ) async throws {
        try await script.exports.loadInstrument(JSValue([
            "instanceId": instanceID.uuidString,
            "moduleName": moduleName,
            "source": source,
            "config": config,
            "restored": restored,
        ]))
    }

    public func disposeInstrumentOnAgent(instanceID: UUID) async throws {
        _ = try await script.exports.disposeInstrument(["instanceId": instanceID.uuidString])
    }

    public func pushInstrumentConfig(instanceID: UUID, config: Any) async throws {
        try await script.exports.updateInstrumentConfig(JSValue([
            "instanceId": instanceID.uuidString,
            "config": config,
        ]))
    }

    public func invokeWidgetAction(instanceID: UUID, widget: String, action: String, item: String?) async throws {
        var payload: [String: Any] = [
            "instanceId": instanceID.uuidString,
            "widget": widget,
            "action": action,
        ]
        if let item { payload["item"] = item }
        _ = try await script.exports.invokeWidgetAction(JSValue(payload))
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

    public func startThreadTraceOnAgent(traceID: UUID, threadID: UInt, threadName: String?) async throws {
        var args: [String: Any] = [
            "sessionId": traceID.uuidString,
            "threadId": Int(threadID),
        ]
        if let threadName {
            args["threadName"] = threadName
        }
        try await script.exports.startThreadTrace(JSValue(args))
    }

    public func stopTraceOnAgent(traceID: UUID) async throws {
        try await script.exports.stopThreadTrace(JSValue([
            "sessionId": traceID.uuidString,
        ]))
    }

    func handleITraceStart(
        sessionId: String,
        origin: ITrace.Origin,
        bufferLocation: String,
        hookTarget: String?,
        prologueBytes: String?
    ) async {
        let pending = PendingTrace(
            id: UUID(uuidString: sessionId) ?? UUID(),
            origin: origin,
            displayName: traceDisplayName(for: origin),
            startedAt: Date(),
            hookTarget: hookTarget,
            prologueBytes: prologueBytes,
            accumulated: Data(),
            lost: 0,
            useSystemDrain: false
        )
        pendingTraces[sessionId] = pending
        emitTraceUpdate(sessionId: sessionId)

        if let drainScript, systemDrainOwner == nil {
            do {
                try await drainScript.exports.openBuffer(bufferLocation)
                pendingTraces[sessionId]?.useSystemDrain = true
                systemDrainOwner = sessionId
                startSystemDrainTimer(for: sessionId)
                return
            } catch {
            }
        }

        startInProcessDrain(sessionId: sessionId)
    }

    func handleITraceChunk(sessionId: String, data: [UInt8], lost: Int) {
        pendingTraces[sessionId]?.accumulated.append(contentsOf: data)
        pendingTraces[sessionId]?.lost = lost
        scheduleRunningTraceEmit(sessionId: sessionId)
    }

    func handleITraceStop(sessionId: String, lost: Int, data: [UInt8]?) async {
        if systemDrainOwner == sessionId, let drainScript {
            drainTimer?.cancel()
            drainTimer = nil
            do {
                if let finalChunk = try await drainScript.exports.close() as? [UInt8], !finalChunk.isEmpty {
                    pendingTraces[sessionId]?.accumulated.append(contentsOf: finalChunk)
                }
                let sysLost = (try? await drainScript.exports.getLost()) as? Int ?? 0
                pendingTraces[sessionId]?.lost = sysLost
            } catch {
            }
            systemDrainOwner = nil
        }

        if let data, !data.isEmpty {
            pendingTraces[sessionId]?.accumulated.append(contentsOf: data)
        }

        let currentLost = pendingTraces[sessionId]?.lost ?? 0
        pendingTraces[sessionId]?.lost = max(currentLost, lost)

        await finalizeTrace(sessionId: sessionId)
    }

    private func scheduleRunningTraceEmit(sessionId: String) {
        guard pendingEmits[sessionId] == nil else { return }
        pendingEmits[sessionId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.runningTraceEmitInterval)
            guard let self, !Task.isCancelled else { return }
            self.pendingEmits.removeValue(forKey: sessionId)
            self.emitTraceUpdate(sessionId: sessionId)
        }
    }

    private func emitTraceUpdate(sessionId: String) {
        cancelPendingEmit(sessionId: sessionId)
        guard let trace = makeRunningTrace(sessionId: sessionId) else { return }
        _traceUpdates.yield(trace)
    }

    private func cancelPendingEmit(sessionId: String) {
        pendingEmits.removeValue(forKey: sessionId)?.cancel()
    }

    private func makeRunningTrace(sessionId: String) -> ITrace? {
        guard let pending = pendingTraces[sessionId] else { return nil }
        let (traceData, metadataJSON) = decodeAccumulated(pending: pending)
        return ITrace(
            id: pending.id,
            sessionID: sessionID,
            origin: pending.origin,
            displayName: pending.displayName,
            startedAt: pending.startedAt,
            stoppedAt: nil,
            metadataJSON: metadataJSON,
            dataSize: traceData.count,
            lost: pending.lost
        )
    }

    public func livePendingTraceData(traceID: UUID) -> Data? {
        for pending in pendingTraces.values where pending.id == traceID {
            let (traceData, _) = decodeAccumulated(pending: pending)
            return traceData
        }
        return nil
    }

    private func decodeAccumulated(pending: PendingTrace) -> (traceData: Data, metadataJSON: Data) {
        return ITraceDecoder.parseRawBuffer(
            pending.accumulated,
            hookTarget: pending.hookTarget,
            prologueBytes: pending.prologueBytes
        )
    }

    private func startInProcessDrain(sessionId: String) {
        inProcessDrainTasks[sessionId]?.cancel()
        inProcessDrainTasks[sessionId] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.inProcessDrainInterval)
                guard let self, !Task.isCancelled else { break }
                if self.pendingTraces[sessionId] == nil { break }
                _ = try? await self.script.exports.drainLocally(sessionId)
            }
        }
    }

    private func cancelInProcessDrain(sessionId: String) {
        inProcessDrainTasks.removeValue(forKey: sessionId)?.cancel()
    }

    private func startSystemDrainTimer(for sessionId: String) {
        drainTimer?.cancel()
        drainTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)

                guard let self, let drainScript = self.drainScript else { break }

                do {
                    if let chunk = try await drainScript.exports.drain() as? [UInt8], !chunk.isEmpty {
                        self.pendingTraces[sessionId]?.accumulated.append(contentsOf: chunk)
                        self.scheduleRunningTraceEmit(sessionId: sessionId)
                    }
                } catch {
                    break
                }
            }
        }
    }

    private func finalizeTrace(sessionId: String) async {
        cancelPendingEmit(sessionId: sessionId)
        cancelInProcessDrain(sessionId: sessionId)
        guard let pending = pendingTraces.removeValue(forKey: sessionId) else { return }
        if systemDrainOwner == sessionId { systemDrainOwner = nil }

        var (traceData, metadataJSON) = decodeAccumulated(pending: pending)
        if case .functionCall = pending.origin {
            ITraceDecoder.cleanupAfterCapture(traceData: &traceData, metadataJSON: &metadataJSON)
        }

        await annotateBlocksWithSymbols(metadataJSON: &metadataJSON)

        try? traceStore?.write(traceData, for: pending.id)

        let trace = ITrace(
            id: pending.id,
            sessionID: sessionID,
            origin: pending.origin,
            displayName: pending.displayName,
            startedAt: pending.startedAt,
            stoppedAt: Date(),
            metadataJSON: metadataJSON,
            dataSize: traceData.count,
            lost: pending.lost
        )
        _traceUpdates.yield(trace)
    }

    private func annotateBlocksWithSymbols(metadataJSON: inout Data) async {
        guard var metadata = try? JSONDecoder().decode(ITraceMetadata.self, from: metadataJSON) else { return }

        let addresses = metadata.blocks.compactMap { ITraceDecoder.parseHexAddress($0.address) }
        guard !addresses.isEmpty else { return }

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

    private func parseTraceOrigin(_ dict: [String: Any]) -> ITrace.Origin? {
        guard let kind = dict["kind"] as? String else { return nil }
        switch kind {
        case "functionCall":
            guard let hookIdString = dict["hookId"] as? String,
                let hookID = UUID(uuidString: hookIdString),
                let callIndex = dict["callIndex"] as? Int
            else { return nil }
            return .functionCall(hookID: hookID, callIndex: callIndex)
        case "thread":
            guard let threadId = dict["threadId"] as? Int else { return nil }
            let threadName = dict["threadName"] as? String
            return .thread(threadID: UInt(threadId), threadName: threadName)
        default:
            return nil
        }
    }

    private func traceDisplayName(for origin: ITrace.Origin) -> String {
        switch origin {
        case .functionCall(let hookID, let callIndex):
            let hookName = instruments.lazy
                .compactMap { ref -> String? in
                    guard let config = try? TracerConfig.decode(from: ref.configJSON) else { return nil }
                    return config.hooks.first(where: { $0.id == hookID })?.displayName
                }
                .first ?? hookID.uuidString
            return "\(hookName) call #\(callIndex)"
        case .thread(let threadID, let threadName):
            let label = threadName ?? "tid \(threadID)"
            return "Thread trace: \(label)"
        }
    }

    private func finalizePendingTracesOnCrash() async {
        let keys = Array(pendingTraces.keys)
        for key in keys {
            await finalizeTrace(sessionId: key)
        }
    }

    public func tearDownITrace() async {
        drainTimer?.cancel()
        drainTimer = nil
        for task in pendingEmits.values { task.cancel() }
        pendingEmits.removeAll()
        for task in inProcessDrainTasks.values { task.cancel() }
        inProcessDrainTasks.removeAll()
        pendingTraces.removeAll()
        systemDrainOwner = nil

        if let drainScript {
            try? await drainScript.unload()
            self.drainScript = nil
        }

        if let systemSession {
            try? await systemSession.detach()
            self.systemSession = nil
        }
    }
}

extension CollaborationSession.Session.Phase {
    public var toProcessSessionPhase: ProcessSession.Phase {
        switch self {
        case .attaching: return .attaching
        case .attached: return .attached
        case .detached: return .idle
        }
    }
}
