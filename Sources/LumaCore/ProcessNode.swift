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

    public let device: Device
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
        public var status: InstrumentStatus?
        public var componentStatuses: [UUID: InstrumentStatus]

        public init(
            id: UUID,
            kind: InstrumentKind,
            sourceIdentifier: String,
            configJSON: Data,
            state: InstrumentState = .enabled,
            attachment: AttachmentState = .detached,
            status: InstrumentStatus? = nil,
            componentStatuses: [UUID: InstrumentStatus] = [:]
        ) {
            self.id = id
            self.kind = kind
            self.sourceIdentifier = sourceIdentifier
            self.configJSON = configJSON
            self.state = state
            self.attachment = attachment
            self.status = status
            self.componentStatuses = componentStatuses
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

    private var systemDrainTasks: [String: Task<Void, Never>] = [:]
    private var pendingTraces: [String: PendingTrace] = [:]
    private var pendingEmits: [String: Task<Void, Never>] = [:]
    private static let runningTraceEmitInterval: UInt64 = 250_000_000
    private static let systemDrainInterval: UInt64 = 50_000_000

    private let drainService: SystemDrainService?
    private let traceStore: TraceStore?

    public var onResolveBlockNames: (@MainActor ([UInt64]) async -> [String])?

    struct PendingTrace {
        let id: UUID
        let origin: ITrace.Origin
        let displayName: String
        let startedAt: Date
        var hookTarget: String?
        var prologueBytes: String?
        var accumulated: Data
        var lost: Int
    }

    public init(
        sessionID: UUID,
        device: Device,
        process: ProcessDetails,
        session: Session,
        script: Script,
        instruments: [InstrumentRef] = [],
        drainService: SystemDrainService? = nil,
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
        self.drainService = drainService
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
                guard let token = dict["token"] as? Int,
                    let sessionId = dict["sessionId"] as? String,
                    let bufferLocation = dict["bufferLocation"] as? String,
                    let originDict = dict["origin"] as? [String: Any],
                    let origin = parseTraceOrigin(originDict)
                else { return false }

                let hookTarget = dict["hookTarget"] as? String
                let prologueBytes = dict["prologueBytes"] as? String
                Task { @MainActor in
                    await self.handleITraceStart(
                        token: token,
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

            case "widget-counter-set":
                guard let update = decodeCounterSetUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-histogram-set":
                guard let update = decodeHistogramSetUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-histogram-increment":
                guard let update = decodeHistogramIncrementUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
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

            case "widget-table-upsert":
                guard let update = decodeTableUpsertUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-table-remove":
                guard let update = decodeTableRemoveUpdate(dict) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-hex-set":
                guard let update = decodeHexSetUpdate(dict, data: data) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-console-append":
                guard let update = decodeConsoleAppendUpdate(dict, data: data) else { return false }
                _widgetUpdates.yield(update)
                return true

            case "widget-console-reply-done":
                guard let update = decodeConsoleReplyDoneUpdate(dict) else { return false }
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

    private func decodeCounterSetUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let counterObj = dict["counter"] as? [String: Any],
            let value = decodeNumber(counterObj["value"])
        else { return nil }
        return WidgetUpdate(
            instanceID: context.instanceID,
            widget: context.widget,
            kind: .counterSet(WidgetCounterValue(
                value: value,
                unit: counterObj["unit"] as? String,
                delta: decodeNumber(counterObj["delta"])
            ))
        )
    }

    private func decodeHistogramSetUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let bucketArr = dict["buckets"] as? [[String: Any]]
        else { return nil }
        let buckets = bucketArr.compactMap { obj -> WidgetHistogramBucket? in
            guard let label = obj["label"] as? String,
                let count = decodeNumber(obj["count"])
            else { return nil }
            return WidgetHistogramBucket(label: label, count: count)
        }
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .histogramSet(buckets))
    }

    private func decodeHistogramIncrementUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let label = dict["label"] as? String,
            let by = decodeNumber(dict["by"])
        else { return nil }
        return WidgetUpdate(
            instanceID: context.instanceID,
            widget: context.widget,
            kind: .histogramIncrement(label: label, by: by)
        )
    }

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

    private func decodeTableUpsertUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let rowObj = dict["row"] as? [String: Any],
            let id = rowObj["id"] as? String,
            let cells = rowObj["cells"] as? [String: String]
        else { return nil }
        return WidgetUpdate(
            instanceID: context.instanceID,
            widget: context.widget,
            kind: .tableUpsert(WidgetTableRow(id: id, cells: cells))
        )
    }

    private func decodeTableRemoveUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let rowID = dict["row"] as? String
        else { return nil }
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .tableRemove(rowID: rowID))
    }

    private func decodeHexSetUpdate(_ dict: [String: Any], data: [UInt8]?) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict) else { return nil }
        let bytes: Data
        if let data {
            bytes = Data(data)
        } else if let b64 = (dict["hex"] as? [String: Any])?["bytes"] as? String,
            let decoded = Data(base64Encoded: b64)
        {
            bytes = decoded
        } else {
            return nil
        }
        let baseAddress: UInt64 = ((dict["hex"] as? [String: Any])?["base_address"] as? NSNumber)?.uint64Value ?? 0
        return WidgetUpdate(
            instanceID: context.instanceID,
            widget: context.widget,
            kind: .hexSet(WidgetHexState(bytes: bytes, baseAddress: baseAddress))
        )
    }

    private func decodeConsoleAppendUpdate(_ dict: [String: Any], data: [UInt8]?) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let entryObj = dict["entry"] as? [String: Any],
            let id = entryObj["id"] as? String,
            let kindStr = entryObj["kind"] as? String,
            let kind = WidgetConsoleEntry.Kind(rawValue: kindStr)
        else { return nil }
        let text = (entryObj["text"] as? String) ?? ""
        let image = decodeConsoleEntryImage(entryObj["image"], data: data)
        let value = image == nil ? decodeConsoleEntryValue(entryObj["value"], data: data) : nil
        let replyTo = entryObj["reply_to"] as? String
        let entry = WidgetConsoleEntry(id: id, kind: kind, text: text, value: value, image: image, replyTo: replyTo)
        return WidgetUpdate(instanceID: context.instanceID, widget: context.widget, kind: .consoleAppend(entry))
    }

    private func decodeConsoleEntryValue(_ raw: Any?, data: [UInt8]?) -> JSInspectValue? {
        guard let raw else { return nil }
        return try? JSInspectValue.decodePacked(tree: raw, blobBytes: data)
    }

    private func decodeConsoleEntryImage(_ raw: Any?, data: [UInt8]?) -> ConsoleImage? {
        guard let obj = raw as? [String: Any],
            let mediaType = obj["media_type"] as? String,
            let width = obj["width"] as? Int,
            let height = obj["height"] as? Int,
            let bytes = data
        else { return nil }
        return ConsoleImage(mediaType: mediaType, data: Data(bytes), width: width, height: height)
    }

    private func decodeConsoleReplyDoneUpdate(_ dict: [String: Any]) -> WidgetUpdate? {
        guard let context = decodeWidgetContext(dict),
            let replyTo = dict["reply_to"] as? String
        else { return nil }
        return WidgetUpdate(
            instanceID: context.instanceID,
            widget: context.widget,
            kind: .consoleReplyDone(inputEntryID: replyTo)
        )
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

    public var evaluateRadare2: ((String) async -> REPLResult.Value)!

    @discardableResult
    public func evalInREPL(_ code: String, language: REPLLanguage = .javascript, cellID: UUID = UUID()) async -> REPLResult? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch language {
        case .javascript:
            return await evalJavaScript(trimmed, cellID: cellID)
        case .r2:
            return await evalRadare2(trimmed, cellID: cellID)
        }
    }

    private func evalJavaScript(_ code: String, cellID: UUID) async -> REPLResult? {
        let (jsCode, pipeline) = splitCodeAndPipeline(code)

        do {
            let anyResult = try await script.exports.evaluate(jsCode, ["raw": pipeline != nil])

            if let pipeline {
                return try await handlePipelineResult(anyResult, cellID: cellID, originalCode: code, pipeline: pipeline)
            }

            guard let jsValue = try? JSInspectValue.decodePacked(from: anyResult) else {
                return nil
            }

            return emitREPLResult(id: cellID, code: code, language: .javascript, value: .js(jsValue))
        } catch {
            return emitREPLResult(id: cellID, code: code, language: .javascript, value: .text("Error: \(error)"))
        }
    }

    private func evalRadare2(_ command: String, cellID: UUID) async -> REPLResult? {
        let value = await evaluateRadare2(command)
        return emitREPLResult(id: cellID, code: command, language: .r2, value: value)
    }

    private func emitREPLResult(id: UUID, code: String, language: REPLLanguage, value: REPLResult.Value) -> REPLResult {
        let result = REPLResult(id: id, code: code, language: language, value: value)
        _replResults.yield(result)
        return result
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
    ) async throws -> REPLResult {
        if let dict = anyResult as? JSONObject,
            let kind = dict["kind"] as? String,
            kind == "error"
        {
            let text = (dict["text"] as? String) ?? "Unknown error"
            return emitREPLResult(id: cellID, code: originalCode, language: .javascript, value: .text(text))
        }

        if let pair = anyResult as? [Any], pair.count == 2, let bytes = pair[1] as? [UInt8] {
            let outputString = try await runPipelineToString(pipeline, input: Data(bytes))
            return emitREPLResult(id: cellID, code: originalCode, language: .javascript, value: .text(outputString))
        }

        if let bytes = anyResult as? [UInt8] {
            let outputString = try await runPipelineToString(pipeline, input: Data(bytes))
            return emitREPLResult(id: cellID, code: originalCode, language: .javascript, value: .text(outputString))
        }

        if let value = anyResult,
            JSONSerialization.isValidJSONObject(value),
            let inputData = try? JSONSerialization.data(withJSONObject: value)
        {
            let outputString = try await runPipelineToString(pipeline, input: inputData)
            return emitREPLResult(id: cellID, code: originalCode, language: .javascript, value: .text(outputString))
        }

        let s = anyResult.map { String(describing: $0) } ?? "null"
        return emitREPLResult(id: cellID, code: originalCode, language: .javascript, value: .text(s))
    }

    private func runPipelineToString(_ command: String, input: Data) async throws -> String {
        let outputData = try await runPipeline(command, input: input)
        return String(data: outputData, encoding: .utf8) ?? "(\(outputData.count) bytes from pipeline)"
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

    public var completeRadare2: ((String, Int) async -> [REPLCompletion])!

    public func completeInREPL(code: String, cursor: Int, language: REPLLanguage = .javascript) async -> [REPLCompletion] {
        let head = String(code.prefix(cursor)).trimmingCharacters(in: .whitespaces)
        if head.hasPrefix(":") {
            return modeCommandCompletions(typed: head.dropFirst().lowercased())
        }
        switch language {
        case .javascript:
            return await completeJavaScript(code: code, cursor: cursor)
        case .r2:
            return await completeRadare2(code, cursor)
        }
    }

    private func modeCommandCompletions(typed: String) -> [REPLCompletion] {
        [
            ("js", "Evaluate JavaScript in the target process"),
            ("r2", "Disassemble and analyze with radare2"),
        ]
        .filter { $0.0.hasPrefix(typed) }
        .map { REPLCompletion(insertText: $0.0, displayText: ":\($0.0)", detailText: $0.1) }
    }

    private func annotatedCompletion(_ name: String, base: String?) -> REPLCompletion {
        let detail = base.flatMap { FridaTypeIndex.detail(for: "\($0).\(name)") } ?? FridaTypeIndex.detail(for: name)
        guard let detail else { return REPLCompletion(name) }
        return REPLCompletion(insertText: name, displayText: name, detailText: detail)
    }

    private func completeJavaScript(code: String, cursor: Int) async -> [REPLCompletion] {
        do {
            let anyResult = try await script.exports.complete(code, cursor)

            if let items = anyResult as? [[String: Any]] {
                let base = Self.completionBase(code: code, cursor: cursor)
                let members = items.compactMap { item -> (name: String, callable: Bool)? in
                    guard let name = item["name"] as? String else { return nil }
                    return (name, (item["callable"] as? Bool) ?? false)
                }
                return members.sorted(by: Self.memberPrecedes).map { annotatedCompletion($0.name, base: base) }
            }
        } catch {
            yieldEngineEvent(subsystem: "repl", level: .warning, text: "Failed to fetch REPL completions: \(error)")
        }

        return []
    }

    private static func completionBase(code: String, cursor: Int) -> String? {
        let end = code.index(code.startIndex, offsetBy: min(cursor, code.count))
        let prefix = code[..<end]
        var start = prefix.endIndex
        while start > prefix.startIndex {
            let prev = prefix.index(before: start)
            let ch = prefix[prev]
            guard ch.isLetter || ch.isNumber || ch == "_" || ch == "$" || ch == "." else { break }
            start = prev
        }
        let token = prefix[start...]
        guard let lastDot = token.lastIndex(of: ".") else { return nil }
        let base = token[..<lastDot]
        let segment = base.lastIndex(of: ".").map { base[base.index(after: $0)...] } ?? base[...]
        return segment.isEmpty ? nil : String(segment)
    }

    private static func memberPrecedes(_ a: (name: String, callable: Bool), _ b: (name: String, callable: Bool)) -> Bool {
        if a.callable != b.callable { return !a.callable }
        let aUnderscored = a.name.hasPrefix("_")
        let bUnderscored = b.name.hasPrefix("_")
        if aUnderscored != bUnderscored { return bUnderscored }
        return a.name.lowercased() < b.name.lowercased()
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

    public func writeRemoteMemory(at address: UInt64, bytes: [UInt8]) async throws {
        let addr = String(format: "0x%llx", address)
        _ = try await script.exports.writeMemory(addr, bytes)
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
            guard let m = modules.first(where: { $0.name == name || $0.path == name }) else {
                throw LumaCoreError.invalidArgument("Module '\(name)' not loaded in the current process")
            }
            return m.base &+ offset

        case .moduleExport(let name, _):
            guard modules.first(where: { $0.name == name || $0.path == name }) != nil else {
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

    public func symbolicate(addresses: [UInt64]) async throws -> [SymbolicateResult?] {
        let raw = try await script.exports.symbolicate(addresses.map { String(format: "0x%llx", $0) })

        guard let arr = raw as? [Any], arr.count == addresses.count else {
            throw LumaCoreError.protocolViolation("Invalid reply")
        }

        return try arr.map(decodeSymbolicateEntry)
    }

    private func decodeSymbolicateEntry(_ entry: Any) throws -> SymbolicateResult? {
        if entry is NSNull { return nil }

        guard let dict = entry as? [String: Any],
            let module = dict["module"] as? String,
            let name = dict["name"] as? String
        else {
            throw LumaCoreError.protocolViolation("Invalid reply")
        }

        let offset = (dict["offset"] as? NSNumber).map { UInt64(truncating: $0) }
        let source = decodeSymbolSource(from: dict)

        return SymbolicateResult(module: module, name: name, offset: offset, source: source)
    }

    private func decodeSymbolSource(from dict: [String: Any]) -> SymbolicateResult.SourceLocation? {
        guard let file = dict["file"] as? String,
            let line = dict["line"] as? Int
        else { return nil }
        let column = dict["column"] as? Int
        return SymbolicateResult.SourceLocation(file: file, line: line, column: column)
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

    public func queryModuleSymbols(
        name: String,
        category: ModuleSymbolCategory,
        query: String,
        offset: Int = 0,
        limit: Int = ModuleSymbolPage.pageSize
    ) async throws -> ModuleSymbolPage {
        let raw = try await script.exports.queryModuleSymbols(JSValue([
            "module": name,
            "category": category.rawValue,
            "query": query,
            "offset": offset,
            "limit": limit,
        ]))
        guard let dict = raw as? [String: Any] else {
            throw LumaCoreError.protocolViolation("queryModuleSymbols: unexpected response shape")
        }
        return ModuleSymbolPage.fromJSON(dict, category: category)
    }

    public func enumerateModuleRanges(name: String) async throws -> [ModuleRange] {
        let raw = try await script.exports.enumerateModuleRanges(name)
        guard let arr = raw as? [[String: Any]] else {
            throw LumaCoreError.protocolViolation("enumerateModuleRanges: unexpected response shape")
        }
        return arr.compactMap { entry in
            guard let offsetStr = entry["offset"] as? String,
                let offset = UInt64(offsetStr.dropFirst(2), radix: 16),
                let size = entry["size"] as? Int,
                let protection = entry["protection"] as? String
            else { return nil }
            return ModuleRange(offset: offset, size: UInt64(size), protection: protection)
        }
    }

    public func getModuleIdentity(name: String) async throws -> String? {
        let raw = try await script.exports.getModuleIdentity(name)
        return raw as? String
    }

    public func findRangeByAddress(_ address: UInt64) async throws -> ProcessRange? {
        let raw = try await script.exports.findRangeByAddress("0x" + String(address, radix: 16))
        guard let entry = raw as? [String: Any] else { return nil }
        guard let baseStr = entry["base"] as? String,
            let size = entry["size"] as? Int,
            let protection = entry["protection"] as? String
        else { return nil }
        let trimmed = baseStr.hasPrefix("0x") ? String(baseStr.dropFirst(2)) : baseStr
        guard let base = UInt64(trimmed, radix: 16) else { return nil }
        return ProcessRange(base: base, size: UInt64(size), protection: protection, filePath: entry["filePath"] as? String)
    }

    public struct ModuleRange: Sendable, Hashable, Codable {
        public let offset: UInt64
        public let size: UInt64
        public let protection: String
    }

    public struct ProcessRange: Sendable, Hashable {
        public let base: UInt64
        public let size: UInt64
        public let protection: String
        public let filePath: String?
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
        public let identity: String

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
            instruments[i].status = nil
        }
    }

    public func markInstrumentDetached(id: UUID) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].attachment = .detached
        }
    }

    public func setInstrumentStatus(id: UUID, _ status: InstrumentStatus) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].attachment = .detached
            instruments[i].status = status
        }
    }

    public func clearInstrumentStatus(id: UUID) {
        if let i = instruments.firstIndex(where: { $0.id == id }) {
            instruments[i].status = nil
        }
    }

    public func replaceComponentStatuses(instrumentID: UUID, _ statuses: [UUID: InstrumentStatus]) {
        if let i = instruments.firstIndex(where: { $0.id == instrumentID }) {
            instruments[i].componentStatuses = statuses
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

    public func submitConsoleInput(instanceID: UUID, widget: String, entryID: String, text: String) async throws {
        try await script.exports.submitConsoleInput(JSValue([
            "instanceId": instanceID.uuidString,
            "widget": widget,
            "entryId": entryID,
            "text": text,
        ]))
    }

    // MARK: - ITrace Orchestration

    func handleITraceStart(
        token: Int,
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
            lost: 0
        )
        pendingTraces[sessionId] = pending
        emitTraceUpdate(sessionId: sessionId)

        let drain = await negotiateDrain(sessionId: sessionId, bufferLocation: bufferLocation)
        script.post(["type": "itrace:ack:\(token)", "drain": drain])
    }

    // The agent is blocked awaiting this ack before it arms Stalker, so the
    // out-of-process remap (which may crash the target) is established here,
    // while the buffer is still intact. task_for_pid capability is fixed per
    // target, so a single denial disqualifies system draining for good.
    private func negotiateDrain(sessionId: String, bufferLocation: String) async -> String {
        guard let drainService,
            await drainService.openBuffer(sessionId: sessionId, location: bufferLocation)
        else {
            return "in-agent"
        }

        startSystemDrainTimer(for: sessionId)
        return "system"
    }

    func handleITraceChunk(sessionId: String, data: [UInt8], lost: Int) {
        pendingTraces[sessionId]?.accumulated.append(contentsOf: data)
        pendingTraces[sessionId]?.lost = lost
        scheduleRunningTraceEmit(sessionId: sessionId)
    }

    func handleITraceStop(sessionId: String, lost: Int, data: [UInt8]?) async {
        if let task = systemDrainTasks.removeValue(forKey: sessionId), let drainService {
            task.cancel()
            do {
                let sysLost = await drainService.lost(sessionId: sessionId)
                if let finalChunk = try await drainService.close(sessionId: sessionId), !finalChunk.isEmpty {
                    pendingTraces[sessionId]?.accumulated.append(contentsOf: finalChunk)
                }
                let mergedLost = max(pendingTraces[sessionId]?.lost ?? 0, sysLost)
                pendingTraces[sessionId]?.lost = mergedLost
            } catch {
            }
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
        let (traceData, metadataJSON, _) = decodeAccumulated(pending: pending)
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
            return decodeAccumulated(pending: pending).traceData
        }
        return nil
    }

    private func decodeAccumulated(pending: PendingTrace) -> (traceData: Data, metadataJSON: Data, panics: [String]) {
        return ITraceDecoder.parseRawBuffer(
            pending.accumulated,
            hookTarget: pending.hookTarget,
            prologueBytes: pending.prologueBytes
        )
    }

    private func startSystemDrainTimer(for sessionId: String) {
        systemDrainTasks[sessionId] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.systemDrainInterval)

                guard let self, let drainService = self.drainService else { break }
                if self.pendingTraces[sessionId] == nil { break }

                do {
                    if let chunk = try await drainService.drain(sessionId: sessionId), !chunk.isEmpty {
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
        systemDrainTasks.removeValue(forKey: sessionId)?.cancel()
        guard let pending = pendingTraces.removeValue(forKey: sessionId) else { return }

        var (traceData, metadataJSON, panics) = decodeAccumulated(pending: pending)
        for panic in panics {
            yieldEngineEvent(subsystem: "itrace", level: .error, text: "Panic: \(panic)")
        }
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
        guard let onResolveBlockNames else { return }
        guard var metadata = try? JSONDecoder().decode(ITraceMetadata.self, from: metadataJSON) else { return }

        let addresses = metadata.blocks.compactMap { ITraceDecoder.parseHexAddress($0.address) }
        guard !addresses.isEmpty else { return }

        let names = await onResolveBlockNames(addresses)
        for (i, name) in names.enumerated() where i < metadata.blocks.count {
            metadata.blocks[i].name = name
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
        // Allow any in-flight `itrace:start` IPC messages from the agent to
        // be processed before we finalize, so we don't drop traces whose
        // start arrived in the same event-loop tick as the detach.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let keys = Array(pendingTraces.keys)
        for key in keys {
            if let task = systemDrainTasks.removeValue(forKey: key), let drainService {
                task.cancel()
                do {
                    if let finalChunk = try await drainService.close(sessionId: key), !finalChunk.isEmpty {
                        pendingTraces[key]?.accumulated.append(contentsOf: finalChunk)
                    }
                } catch {
                }
            }
            await finalizeTrace(sessionId: key)
        }
    }

    public func tearDownITrace() async {
        let drainedSessions = Array(systemDrainTasks.keys)
        for task in systemDrainTasks.values { task.cancel() }
        systemDrainTasks.removeAll()
        for task in pendingEmits.values { task.cancel() }
        pendingEmits.removeAll()
        pendingTraces.removeAll()

        if let drainService {
            for sessionId in drainedSessions {
                _ = try? await drainService.close(sessionId: sessionId)
            }
        }
    }

    private func yieldEngineEvent(subsystem: String, level: ConsoleLevel, text: String) {
        _events.yield(RuntimeEvent(
            source: .engine(subsystem: subsystem),
            payload: .consoleMessage(ConsoleMessage(level: level, values: [.string(text)]))
        ))
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
