import Foundation
import Frida

@MainActor
public final class Engine {
    public let deviceManager = DeviceManager()
    public let store: ProjectStore
    public let compilerWorkspace: CompilerWorkspace

    public private(set) var processNodes: [ProcessNode] = []
    public private(set) var descriptors: [InstrumentDescriptor] = []
    private var descriptorsByID: [String: InstrumentDescriptor] = [:]

    private let _events = AsyncEventSource<RuntimeEvent>()
    public var events: AsyncStream<RuntimeEvent> { _events.makeStream() }

    public let eventLog = EventLog()

    private var deviceEventTasks: [String: Task<Void, Never>] = [:]
    private var eventLogTask: Task<Void, Never>?

    public var hookPackSourceProvider: ((String) -> (entrySource: String, packID: String)?)?
    public var hookPackDescriptorProvider: (() -> [InstrumentDescriptor])?

    public let collaboration: CollaborationSession
    public let dataDirectory: URL

    public init(store: ProjectStore, dataDirectory: URL) {
        self.store = store
        self.dataDirectory = dataDirectory
        self.compilerWorkspace = CompilerWorkspace(store: store)
        self.collaboration = CollaborationSession(
            deviceManager: deviceManager,
            store: store,
            portalAddress: BackendConfig.portalAddress,
            portalCertificate: BackendConfig.certificate
        )

        registerDescriptor(Self.tracerDescriptor)
        bindCollaborationCallbacks()

        eventLogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self._events.makeStream() {
                self.eventLog.append(event)
            }
        }
    }

    // MARK: - Notebook Operations

    public func addNotebookEntry(_ entry: NotebookEntry, after otherEntry: NotebookEntry? = nil) {
        var e = entry
        if let otherEntry {
            e.timestamp = otherEntry.timestamp.addingTimeInterval(0.001)
        }
        try? store.save(e)
        collaboration.notifyEntryAdded(e)
    }

    public func updateNotebookEntry(_ entry: NotebookEntry) {
        try? store.save(entry)
        collaboration.notifyEntryUpdated(entry)
    }

    public func deleteNotebookEntry(_ entry: NotebookEntry) {
        try? store.deleteNotebookEntry(id: entry.id)
        collaboration.notifyEntryDeleted(id: entry.id)
    }

    public func bindCollaborationCallbacks() {
        collaboration.onNotebookEntriesReceived = { [weak self] entries in
            guard let self else { return }
            for entry in entries {
                try? self.store.save(entry)
            }
        }

        collaboration.onNotebookEntryAdded = { [weak self] entry in
            guard let self else { return }
            if (try? self.store.fetchNotebookEntry(id: entry.id)) == nil {
                try? self.store.save(entry)
            }
        }

        collaboration.onNotebookEntryUpdated = { [weak self] updated in
            guard let self else { return }
            if var existing = try? self.store.fetchNotebookEntry(id: updated.id) {
                existing.title = updated.title
                existing.details = updated.details
                existing.timestamp = updated.timestamp
                existing.processName = updated.processName
                existing.isUserNote = updated.isUserNote
                try? self.store.save(existing)
            }
        }

        collaboration.onNotebookEntryDeleted = { [weak self] id in
            try? self?.store.deleteNotebookEntry(id: id)
        }

        collaboration.onEntriesReordered = { [weak self] order in
            guard let self else { return }
            var t = Date()
            for id in order {
                if var entry = try? self.store.fetchNotebookEntry(id: id) {
                    entry.timestamp = t
                    try? self.store.save(entry)
                    t = t.addingTimeInterval(0.001)
                }
            }
        }
    }

    public func loadRemoteDevices() async {
        for config in (try? store.fetchRemoteDevices()) ?? [] {
            do {
                _ = try await deviceManager.addRemoteDevice(
                    address: config.address,
                    certificate: config.certificate,
                    origin: config.origin,
                    token: config.token,
                    keepaliveInterval: config.keepaliveInterval
                )
            } catch {
                NSLog("[Engine] failed to add remote device %@: %@", config.address, String(describing: error))
            }
        }
    }

    // MARK: - Descriptor Registry

    public func registerDescriptor(_ descriptor: InstrumentDescriptor) {
        if let idx = descriptors.firstIndex(where: { $0.id == descriptor.id }) {
            descriptors[idx] = descriptor
        } else {
            descriptors.append(descriptor)
        }
        descriptorsByID[descriptor.id] = descriptor
    }

    public func reloadHookPackDescriptors() {
        descriptors.removeAll { $0.kind == .hookPack }
        for key in descriptorsByID.keys where key.hasPrefix("hook-pack:") {
            descriptorsByID.removeValue(forKey: key)
        }

        if let provider = hookPackDescriptorProvider {
            for desc in provider() {
                registerDescriptor(desc)
            }
        }
    }

    public func descriptor(for instance: InstrumentInstance) -> InstrumentDescriptor? {
        switch instance.kind {
        case .tracer:
            return descriptorsByID["tracer"]
        case .hookPack:
            return descriptorsByID["hook-pack:\(instance.sourceIdentifier)"]
        case .codeShare:
            return descriptorsByID["codeshare:\(instance.sourceIdentifier)"]
                ?? makeCodeShareDescriptor(for: instance)
        }
    }

    private func makeCodeShareDescriptor(for instance: InstrumentInstance) -> InstrumentDescriptor? {
        guard
            let cfg = try? JSONDecoder().decode(CodeShareConfig.self, from: instance.configJSON)
        else {
            return nil
        }

        return InstrumentDescriptor(
            id: "codeshare:\(instance.sourceIdentifier)",
            kind: .codeShare,
            sourceIdentifier: instance.sourceIdentifier,
            displayName: cfg.name,
            icon: .system("cloud"),
            makeInitialConfigJSON: { try! JSONEncoder().encode(cfg) }
        )
    }

    public static let tracerDescriptor = InstrumentDescriptor(
        id: "tracer",
        kind: .tracer,
        sourceIdentifier: "builtin.tracer",
        displayName: "Tracer",
        icon: .system("arrow.triangle.branch"),
        makeInitialConfigJSON: {
            try! JSONEncoder().encode(TracerConfig())
        },
        summarizeEvent: { event in
            String(describing: event.payload)
        }
    )

    // MARK: - Session Orchestration

    public func spawnAndAttach(
        device: Device,
        session: ProcessSession
    ) async {
        guard case .spawn(let config) = session.kind else {
            fatalError("spawnAndAttach requires a spawn session")
        }

        var s = session
        s.phase = .attaching
        s.detachReason = .applicationRequested
        s.lastError = nil
        try? store.save(s)

        ensureDeviceEventsHooked(for: device)

        do {
            let pid = try await device.spawn(
                config.programString,
                argv: config.argvParam,
                envp: nil,
                env: config.envParam,
                cwd: config.cwdParam,
                stdio: config.stdio
            )

            let procs = try await device.enumerateProcesses(pids: [pid], scope: .full)
            guard let process = procs.first else {
                s.lastError = "Spawned pid \(pid) not found"
                s.phase = .idle
                try? store.save(s)
                return
            }

            s.deviceName = device.name
            try? store.save(s)

            await performAttach(
                device: device,
                process: process,
                session: s
            )

            s = (try? store.fetchSession(id: s.id)) ?? s
            if config.autoResume {
                try await device.resume(pid)
                s.phase = .attached
            } else {
                s.phase = .awaitingInitialResume
            }
            try? store.save(s)
        } catch {
            s.lastError = error.localizedDescription
            s.phase = .idle
            try? store.save(s)
        }
    }

    public func attach(
        device: Device,
        process: ProcessDetails,
        session: ProcessSession
    ) async {
        await performAttach(
            device: device,
            process: process,
            session: session
        )
    }

    private func performAttach(
        device: Device,
        process: ProcessDetails,
        session: ProcessSession
    ) async {
        var s = session
        s.lastKnownPID = process.pid
        s.detachReason = .applicationRequested
        s.lastError = nil
        s.phase = .attaching
        try? store.save(s)

        do {
            ensureDeviceEventsHooked(for: device)

            let fridaSession = try await device.attach(to: process.pid)

            updateSession(id: s.id) { $0.lastAttachedAt = Date() }

            let script = try await fridaSession.createScript(
                LumaAgent.coreSource,
                name: "luma",
                runtime: .auto
            )

            let instruments = (try? store.fetchInstruments(sessionID: s.id)) ?? []
            let instrumentRefs = instruments.map {
                ProcessNode.InstrumentRef(
                    id: $0.id, kind: $0.kind,
                    sourceIdentifier: $0.sourceIdentifier,
                    configJSON: $0.configJSON,
                    isEnabled: $0.isEnabled
                )
            }

            let node = ProcessNode(
                device: device,
                process: process,
                session: fridaSession,
                script: script,
                instruments: instrumentRefs,
                drainAgentSource: LumaAgent.drainSource
            )

            let existingCells = (try? store.fetchREPLCells(sessionID: s.id)) ?? []
            if !existingCells.isEmpty {
                let cell = REPLCell(
                    sessionID: s.id,
                    code: "New process attached",
                    result: .text(""),
                    isSessionBoundary: true
                )
                try? store.save(cell)
            }

            subscribeToNodeStreams(node, sessionID: s.id)

            processNodes.append(node)

            await node.waitForScriptEventsSubscription()
            await Task.yield()

            try await script.load()

            if let info = await node.fetchProcessInfo() {
                updateSession(id: s.id) {
                    $0.processInfo = ProcessSession.ProcessInfo(
                        platform: info.platform,
                        arch: info.arch,
                        pointerSize: info.pointerSize
                    )
                }
            }

            await node.setupITraceDraining()

            await loadAllPackages(on: node, sessionID: s.id)

            for ref in node.instruments where ref.isEnabled {
                await loadInstrumentOnNode(
                    instanceID: ref.id,
                    kind: ref.kind,
                    sourceIdentifier: ref.sourceIdentifier,
                    configJSON: ref.configJSON,
                    node: node,
                    sessionID: s.id
                )
            }

            updateSession(id: s.id) { $0.phase = .attached }
        } catch {
            NSLog("[Engine] attach failed: %@", String(describing: error))
            updateSession(id: s.id) {
                $0.lastError = error.localizedDescription
                $0.phase = .idle
            }
        }
    }

    public func resumeSpawnedProcess(node: ProcessNode) async {
        guard let session = try? store.fetchSession(id: nodeSessionID(node)) else { return }
        let pid = session.lastKnownPID

        do {
            try await node.device.resume(pid)
            updateSession(id: session.id) { $0.phase = .attached }
        } catch {
            updateSession(id: session.id) {
                $0.lastError = error.localizedDescription
            }
        }
    }

    public func removeNode(_ node: ProcessNode) {
        if let idx = processNodes.firstIndex(where: { $0.id == node.id }) {
            processNodes.remove(at: idx)
            node.stop()
        }
    }

    public func node(forSessionID sessionID: UUID) -> ProcessNode? {
        processNodes.first { $0.id == sessionID || nodeSessionID($0) == sessionID }
    }

    public func sessionID(for node: ProcessNode) -> UUID {
        nodeSessionID(node)
    }

    // MARK: - Reestablish Session

    public enum ReestablishResult {
        case attached
        case needsUserInput(reason: String, session: ProcessSession)
    }

    public func reestablishSession(id sessionID: UUID) async -> ReestablishResult {
        guard var s = try? store.fetchSession(id: sessionID) else {
            return .needsUserInput(
                reason: "Session not found.",
                session: ProcessSession(kind: .attach, deviceID: "", deviceName: "", processName: "", lastKnownPID: 0)
            )
        }

        s.phase = .attaching
        s.detachReason = .applicationRequested
        s.lastError = nil
        try? store.save(s)

        let devices = await deviceManager.currentDevices()

        guard let device = devices.first(where: { $0.id == s.deviceID }) else {
            s.phase = .idle
            try? store.save(s)
            return .needsUserInput(
                reason: "The saved device \"\(s.deviceName)\" is not available. Choose a device and target to re-establish this session.",
                session: s
            )
        }

        if case .spawn(_) = s.kind {
            await spawnAndAttach(device: device, session: s)
            return .attached
        }

        do {
            let processes = try await device.enumerateProcesses(scope: Scope.full)
            let matches = processes.filter { $0.name == s.processName }

            guard !matches.isEmpty else {
                s.phase = .idle
                try? store.save(s)
                return .needsUserInput(
                    reason: "No running process named \"\(s.processName)\" was found. Choose a new target to re-establish this session.",
                    session: s
                )
            }

            let chosen: ProcessDetails
            if let exact = matches.first(where: { $0.pid == s.lastKnownPID }) {
                chosen = exact
            } else if matches.count == 1 {
                chosen = matches[0]
            } else {
                s.phase = .idle
                try? store.save(s)
                return .needsUserInput(
                    reason: "Multiple processes named \"\(s.processName)\" are running. Choose which one to attach to.",
                    session: s
                )
            }

            s.deviceName = device.name
            try? store.save(s)

            await performAttach(device: device, process: chosen, session: s)
            return .attached
        } catch {
            s.lastError = error.localizedDescription
            s.phase = .idle
            try? store.save(s)
            return .needsUserInput(
                reason: "Quick re-establish failed for \"\(s.processName)\". Choose a new target.",
                session: s
            )
        }
    }

    // MARK: - Instrument Lifecycle

    @discardableResult
    public func addInstrument(
        kind: InstrumentKind,
        sourceIdentifier: String,
        configJSON: Data,
        sessionID: UUID
    ) async -> InstrumentInstance {
        let instance = InstrumentInstance(
            sessionID: sessionID,
            kind: kind,
            sourceIdentifier: sourceIdentifier,
            configJSON: configJSON
        )
        try? store.save(instance)

        if let node = node(forSessionID: sessionID) {
            node.addInstrument(ProcessNode.InstrumentRef(
                id: instance.id, kind: instance.kind,
                sourceIdentifier: instance.sourceIdentifier,
                configJSON: instance.configJSON,
                isEnabled: instance.isEnabled
            ))

            await loadInstrumentOnNode(
                instanceID: instance.id,
                kind: instance.kind,
                sourceIdentifier: instance.sourceIdentifier,
                configJSON: instance.configJSON,
                node: node,
                sessionID: sessionID
            )
        }

        return instance
    }

    public func removeInstrument(id: UUID, sessionID: UUID) async {
        if let node = node(forSessionID: sessionID) {
            if node.instruments.first(where: { $0.id == id })?.isAttached == true {
                try? await node.script.exports.disposeInstrument(["instanceId": id.uuidString])
            }
            node.removeInstrument(id: id)
        }
        try? store.deleteInstrument(id: id)
    }

    public func setInstrumentEnabled(instanceID: UUID, sessionID: UUID, enabled: Bool) async {
        guard var inst = try? store.fetchInstrument(id: instanceID) else { return }
        inst.isEnabled = enabled
        try? store.save(inst)

        guard let node = node(forSessionID: sessionID) else { return }

        if enabled {
            guard node.instruments.first(where: { $0.id == instanceID })?.isAttached != true else { return }

            await loadInstrumentOnNode(
                instanceID: instanceID,
                kind: inst.kind,
                sourceIdentifier: inst.sourceIdentifier,
                configJSON: inst.configJSON,
                node: node,
                sessionID: sessionID
            )
        } else {
            if node.instruments.first(where: { $0.id == instanceID })?.isAttached == true {
                try? await node.script.exports.disposeInstrument(["instanceId": instanceID.uuidString])
                node.markInstrumentDetached(id: instanceID)
            }
        }
    }

    public func applyInstrumentConfig(instanceID: UUID, sessionID: UUID, configJSON: Data) async {
        guard var inst = try? store.fetchInstrument(id: instanceID) else { return }
        inst.configJSON = configJSON
        try? store.save(inst)

        guard let node = node(forSessionID: sessionID) else { return }

        node.updateInstrumentConfig(id: instanceID, configJSON: configJSON)

        guard node.instruments.first(where: { $0.id == instanceID })?.isAttached == true else { return }

        let configObject: JSONObject
        switch inst.kind {
        case .tracer:
            let config = (try? TracerConfig.decode(from: configJSON)) ?? TracerConfig()
            do {
                let paths = try compilerWorkspacePaths()
                configObject = try await compileTracerConfig(config, paths: paths)
            } catch {
                NSLog("[Engine] Failed to compile tracer config: %@", String(describing: error))
                return
            }

        case .hookPack:
            let config = (try? HookPackConfig.decode(from: configJSON))
                ?? HookPackConfig(packId: inst.sourceIdentifier, features: [:])
            configObject = config.toJSON()

        case .codeShare:
            configObject = (try? JSONSerialization.jsonObject(with: configJSON, options: []) as? JSONObject) ?? [:]
        }

        do {
            try await node.script.exports.updateInstrumentConfig(
                JSValue([
                    "instanceId": instanceID.uuidString,
                    "config": configObject,
                ]))
        } catch {
            NSLog("[Engine] Failed to update instrument config: %@", String(describing: error))
        }
    }

    private func loadInstrumentOnNode(
        instanceID: UUID,
        kind: InstrumentKind,
        sourceIdentifier: String,
        configJSON: Data,
        node: ProcessNode,
        sessionID: UUID
    ) async {
        do {
            switch kind {
            case .tracer:
                try await loadTracerInstrument(
                    instanceID: instanceID,
                    config: (try? TracerConfig.decode(from: configJSON)) ?? TracerConfig(),
                    sessionID: sessionID,
                    paths: try compilerWorkspacePaths()
                )

            case .hookPack:
                guard let provider = hookPackSourceProvider,
                    let info = provider(sourceIdentifier)
                else { return }

                try await loadHookPackInstrument(
                    instanceID: instanceID,
                    packID: info.packID,
                    entrySource: info.entrySource,
                    configJSON: configJSON,
                    on: node
                )

            case .codeShare:
                let cfg = try JSONDecoder().decode(CodeShareConfig.self, from: configJSON)
                try await loadCodeShareInstrument(
                    instanceID: instanceID,
                    config: cfg,
                    configJSON: configJSON,
                    on: node
                )
            }

            node.markInstrumentAttached(id: instanceID)
        } catch {
            NSLog("[Engine] Failed to load instrument %@: %@", instanceID.uuidString, String(describing: error))
        }
    }

    // MARK: - Tracer Instruction Hook

    public func addTracerInstructionHook(
        sessionID: UUID,
        address: UInt64
    ) async -> (instrumentID: UUID, hookID: UUID)? {
        guard (try? store.fetchSession(id: sessionID)) != nil else { return nil }

        let tracer: InstrumentInstance
        if let existing = tracerInstance(forSessionID: sessionID) {
            tracer = existing
        } else {
            let configJSON = TracerConfig().encode()
            tracer = await addInstrument(
                kind: .tracer,
                sourceIdentifier: "builtin.tracer",
                configJSON: configJSON,
                sessionID: sessionID
            )
        }

        let anchor: AddressAnchor
        if let node = node(forSessionID: sessionID) {
            anchor = node.anchor(for: address)
        } else {
            anchor = .absolute(address)
        }

        var config = (try? TracerConfig.decode(from: tracer.configJSON)) ?? TracerConfig()

        if let existingID = config.hooks.first(where: { $0.addressAnchor == anchor })?.id {
            return (instrumentID: tracer.id, hookID: existingID)
        }

        let stub = defaultTracerInstructionStub.replacingOccurrences(of: "INSTRUCTION", with: anchor.displayString)

        let newHook = TracerConfig.Hook(
            id: UUID(),
            displayName: String(format: "0x%llx", address),
            addressAnchor: anchor,
            isEnabled: true,
            code: stub
        )

        config.hooks.append(newHook)

        let configData = config.encode()
        await applyInstrumentConfig(instanceID: tracer.id, sessionID: sessionID, configJSON: configData)

        return (instrumentID: tracer.id, hookID: newHook.id)
    }

    // MARK: - Tracer Hook Address Data

    public func tracerHookAddresses(sessionID: UUID) -> [UInt64: UUID] {
        guard let tracer = tracerInstance(forSessionID: sessionID),
            let node = node(forSessionID: sessionID),
            let config = try? TracerConfig.decode(from: tracer.configJSON)
        else {
            return [:]
        }

        var map: [UInt64: UUID] = [:]
        for hook in config.hooks where hook.isEnabled {
            guard let addr = try? node.resolveSyncIfReady(hook.addressAnchor) else { continue }
            map[addr] = hook.id
        }
        return map
    }

    public func tracerInstanceID(sessionID: UUID) -> UUID? {
        tracerInstance(forSessionID: sessionID)?.id
    }

    private func tracerInstance(forSessionID sessionID: UUID) -> InstrumentInstance? {
        let instruments = (try? store.fetchInstruments(sessionID: sessionID)) ?? []
        return instruments.first(where: { $0.kind == .tracer })
    }

    // MARK: - Tracer Compilation

    public func compileTracerConfig(
        _ config: TracerConfig,
        paths: CompilerWorkspacePaths
    ) async throws -> JSONObject {
        _ = try await compilerWorkspace.ensureReady(paths: paths)

        let results: [(Int, String, TracerConfig.Hook)] =
            try await withThrowingTaskGroup(
                of: (Int, String, TracerConfig.Hook).self
            ) { group in
                for (index, hook) in config.hooks.enumerated() {
                    group.addTask {
                        let js = try await self.compileTracerHook(
                            id: hook.id,
                            tsSource: hook.code,
                            paths: paths
                        )
                        return (index, js, hook)
                    }
                }

                var out: [(Int, String, TracerConfig.Hook)] = []
                out.reserveCapacity(config.hooks.count)
                for try await item in group {
                    out.append(item)
                }
                return out
            }

        var hooksJSON: [JSONObject] = []
        hooksJSON.reserveCapacity(results.count)

        for (_, js, hook) in results.sorted(by: { $0.0 < $1.0 }) {
            var dict: JSONObject = [
                "id": hook.id.uuidString,
                "displayName": hook.displayName,
                "addressAnchor": hook.addressAnchor.toJSON(),
                "isEnabled": hook.isEnabled,
                "code": js,
            ]
            if hook.isPinned { dict["isPinned"] = true }
            if hook.itraceEnabled { dict["itraceEnabled"] = true }
            hooksJSON.append(dict)
        }

        return ["hooks": hooksJSON]
    }

    private func compileTracerHook(
        id: UUID,
        tsSource: String,
        paths: CompilerWorkspacePaths
    ) async throws -> String {
        let fm = FileManager.default

        let dirRelPath = "TracerHooks"
        let dirURL = paths.root.appendingPathComponent(dirRelPath, isDirectory: true)

        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        let moduleRelPath = "\(dirRelPath)/\(id.uuidString).ts"
        let entryRelPath = "\(dirRelPath)/\(id.uuidString).entry.ts"

        let moduleURL = paths.root.appendingPathComponent(moduleRelPath)
        let entryURL = paths.root.appendingPathComponent(entryRelPath)

        try tsSource.write(to: moduleURL, atomically: true, encoding: .utf8)

        let entrySource = """
            import "./\(id.uuidString).ts";
            export {};
            """
        try entrySource.write(to: entryURL, atomically: true, encoding: .utf8)

        let options = BuildOptions()
        options.projectRoot = paths.root.path
        options.typeCheck = .none
        options.sourceMaps = .omitted
        options.compression = .terser

        let bundle = try await compilerWorkspace.withCompilerDiagnostics(label: "tracer hook \(id.uuidString)") { compiler in
            try await compiler.build(entrypoint: entryRelPath, options: options)
        }

        let modules = try ESMBundleParser.parse(bundle)
        return modules.modules[modules.order[0]]!
    }

    // MARK: - Instrument Loading

    public func loadTracerInstrument(
        instanceID: UUID,
        config: TracerConfig,
        sessionID: UUID,
        paths: CompilerWorkspacePaths
    ) async throws {
        guard let node = node(forSessionID: sessionID) else { return }

        var compiled = try await compileTracerConfig(config, paths: paths)

        var counters: [String: Int] = [:]
        let captures = (try? store.fetchITraceCaptures(sessionID: sessionID)) ?? []
        for capture in captures {
            let key = capture.hookID.uuidString
            counters[key] = max(counters[key] ?? 0, capture.callIndex + 1)
        }
        if !counters.isEmpty {
            compiled["callCounters"] = counters
        }

        try await node.script.exports.loadInstrument(
            JSValue([
                "instanceId": instanceID.uuidString,
                "moduleName": "/builtin/tracer.js",
                "source": LumaAgent.tracerSource,
                "config": compiled,
            ]))
    }

    public func loadHookPackInstrument(
        instanceID: UUID,
        packID: String,
        entrySource: String,
        configJSON: Data,
        on node: ProcessNode
    ) async throws {
        let config = try InstrumentConfigCodec.decode(HookPackConfig.self, from: configJSON)

        let data = Data(entrySource.utf8)
        let digest = SHA256.hash(data: data)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/hookpacks/\(packID)/\(hashHex).js"

        try await node.script.exports.loadInstrument(
            JSValue([
                "instanceId": instanceID.uuidString,
                "moduleName": moduleName,
                "source": entrySource,
                "config": config.toJSON(),
            ]))
    }

    public func loadCodeShareInstrument(
        instanceID: UUID,
        config: CodeShareConfig,
        configJSON: Data,
        on node: ProcessNode
    ) async throws {
        let configObject: Any
        if configJSON.isEmpty {
            configObject = [:]
        } else {
            configObject = try JSONSerialization.jsonObject(with: configJSON, options: [])
        }

        let data = Data(config.source.utf8)
        let digest = SHA256.hash(data: data)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let moduleName = "/codeshare/\(config.project?.slug ?? config.name)/\(hashHex).js"

        try await node.script.exports.loadInstrument(
            JSValue([
                "instanceId": instanceID.uuidString,
                "moduleName": moduleName,
                "source": LumaAgent.codeShareSource,
                "config": configObject,
            ]))
    }

    // MARK: - Package Loading

    public func loadAllPackages(on node: ProcessNode, sessionID: UUID) async {
        do {
            guard let paths = compilerWorkspace.workspaceRoot.map({ CompilerWorkspacePaths(root: $0) }) else { return }
            let bundles = try await compilerWorkspace.currentPackageBundlesForAgent(paths: paths)
            guard !bundles.isEmpty else { return }

            try await node.script.exports.loadPackages(JSValue(bundles))

            for entry in bundles {
                node.loadedPackageNames.insert(entry["name"] as! String)
            }
        } catch {
            NSLog("[Engine] failed to load packages: %@", String(describing: error))
        }
    }

    // MARK: - Insight Management

    public func getOrCreateInsight(
        sessionID: UUID,
        pointer: UInt64,
        kind: AddressInsight.Kind
    ) throws -> AddressInsight {
        guard let node = node(forSessionID: sessionID) else {
            throw LumaCoreError.invalidOperation("No attached process")
        }

        let anchor = node.anchor(for: pointer)

        let existing = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        if let match = existing.first(where: { $0.kind == kind && $0.anchor == anchor }) {
            return match
        }

        let insight = AddressInsight(
            sessionID: sessionID,
            title: anchor.displayString,
            kind: kind,
            anchor: anchor
        )
        try store.save(insight)
        return insight
    }

    // MARK: - Tracer Event Parsing

    public static func parseTracerEvent(from value: JSInspectValue) -> (
        id: UUID,
        timestamp: Double,
        threadId: Int,
        depth: Int,
        caller: JSInspectValue,
        backtrace: [JSInspectValue]?,
        message: JSInspectValue
    )? {
        guard case .array(_, let elements) = value,
            elements.count == 7
        else { return nil }

        guard case .string(let rawId) = elements[0],
            let id = UUID(uuidString: rawId)
        else { return nil }

        guard case .number(let timestamp) = elements[1] else { return nil }

        guard case .number(let threadIdNum) = elements[2],
            threadIdNum.isFinite,
            threadIdNum.rounded(.towardZero) == threadIdNum
        else { return nil }

        guard case .number(let depthNum) = elements[3],
            depthNum.isFinite,
            depthNum.rounded(.towardZero) == depthNum
        else { return nil }

        let caller = elements[4]
        guard case .nativePointer = caller else { return nil }

        guard case .array(_, let btElements) = elements[5] else { return nil }

        var ptrs: [JSInspectValue] = []
        ptrs.reserveCapacity(btElements.count)
        for e in btElements {
            guard case .nativePointer = e else { return nil }
            ptrs.append(e)
        }

        guard case .array(_, _) = elements[6] else { return nil }

        return (
            id: id,
            timestamp: timestamp,
            threadId: Int(threadIdNum),
            depth: Int(depthNum),
            caller: caller,
            backtrace: ptrs.isEmpty ? nil : ptrs,
            message: elements[6]
        )
    }

    // MARK: - Compiler Workspace Paths

    public func compilerWorkspacePaths() throws -> CompilerWorkspacePaths {
        let packagesState = try store.fetchPackagesState()
        let fm = FileManager.default

        let root = dataDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(packagesState.id.uuidString, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)

        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return CompilerWorkspacePaths(root: root)
    }

    // MARK: - Private Helpers

    private var nodeSessionIDs: [UUID: UUID] = [:]

    private func nodeSessionID(_ node: ProcessNode) -> UUID {
        nodeSessionIDs[node.id] ?? UUID()
    }

    private func subscribeToNodeStreams(_ node: ProcessNode, sessionID: UUID) {
        nodeSessionIDs[node.id] = sessionID

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await reason in node.detachEvents {
                guard let self else { return }
                self.updateSession(id: sessionID) { $0.detachReason = reason }
                self.removeNode(node)
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await event in node.events {
                self?._events.yield(event)
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await result in node.replResults {
                let resultValue: REPLCell.Result
                switch result.value {
                case .js(let v): resultValue = .js(v)
                case .text(let t): resultValue = .text(t)
                }
                let cell = REPLCell(
                    sessionID: sessionID,
                    code: result.code,
                    result: resultValue,
                    timestamp: result.timestamp
                )
                try? self?.store.save(cell)
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await capture in node.captures {
                let record = ITraceCaptureRecord(from: capture, sessionID: sessionID)
                try? self?.store.save(record)
            }
        }

        Task { @MainActor [weak self, weak node] in
            guard let node else { return }
            for await modules in node.moduleSnapshots {
                self?.updateSession(id: sessionID) {
                    $0.lastKnownModules = modules.map {
                        ProcessSession.PersistedModule(name: $0.name, base: $0.base, size: $0.size)
                    }
                }
            }
        }
    }

    private func updateSession(id: UUID, _ mutate: (inout ProcessSession) -> Void) {
        guard var s = try? store.fetchSession(id: id) else { return }
        mutate(&s)
        try? store.save(s)
    }

    private func ensureDeviceEventsHooked(for device: Device) {
        guard deviceEventTasks[device.id] == nil else { return }

        deviceEventTasks[device.id] = Task { [weak self] in
            guard let self else { return }

            for await devEvent in device.events {
                switch devEvent {
                case .output(let data, let fd, let pid):
                    self.handleDeviceOutput(device: device, data: data, fd: fd, pid: pid)

                case .lost:
                    self.deviceEventTasks[device.id]?.cancel()
                    self.deviceEventTasks[device.id] = nil
                    return

                default:
                    break
                }
            }
        }
    }

    private func handleDeviceOutput(device: Device, data: [UInt8], fd: Int, pid: UInt) {
        guard processNodes.first(where: { $0.device.id == device.id && $0.process.pid == pid }) != nil else { return }

        _events.yield(RuntimeEvent(
            source: .processOutput(fd: fd),
            payload: .raw(
                message: String(bytes: data, encoding: .utf8) ?? "(\(data.count) bytes on fd \(fd))",
                data: data
            ),
            data: data
        ))
    }
}

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
