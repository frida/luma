import Combine
import Frida
import SwiftUI
import SwiftyMonaco
import LumaCore

@MainActor
final class Workspace: ObservableObject {
    let engine: Engine

    var deviceManager: DeviceManager { engine.deviceManager }

    @Published var processNodes: [ProcessNodeViewModel] = []
    @Published var sessions: [LumaCore.ProcessSession] = []

    private var addressAnnotationsBySession: [UUID: [UInt64: AddressAnnotation]] = [:]
    private var tracerInstanceIDBySession: [UUID: UUID] = [:]

    struct AddressAnnotation {
        var decorations: [InstrumentAddressDecoration] = []
        var tracerHookID: UUID? = nil
    }

    @Published private(set) var events: [RuntimeEvent] = []
    @Published private(set) var eventsVersion: Int = 0

    private var allEvents: [RuntimeEvent] = []
    private var totalEventsReceived: Int = 0
    private let maxEventsVisible = 1_000
    private let maxEventsInMemory = 10_000
    private var isEventFlushScheduled = false

    @Published var notebookEntries: [LumaCore.NotebookEntry] = []

    @Published var targetPickerContext: TargetPickerContext?

    let packageManager = PackageManager()
    let packageOps = PackageOperationQueue()
    var compilerWorkspaceRoot: URL?
    var packageBundles: [String: String] = [:]
    var packageBundlesDirty: Bool = true
    @Published var lastCompilerDiagnostics: [String] = []
    @Published var monacoFSSnapshot: MonacoFSSnapshot? = nil
    var monacoFSSnapshotDirty: Bool = true
    var monacoFSSnapshotVersion: Int = 0

    @Published var isAuthSheetPresented: Bool = false
    @Published var authState: GitHubAuthState = .signedOut
    @Published var currentGitHubUser: UserInfo?
    @Published var githubToken: String? {
        didSet {
            Task { await loadCurrentGitHubUser() }
        }
    }

    var collaborationState: LumaCore.ProjectCollaborationState?
    @Published var collaborationStatus: CollaborationStatus = .disconnected
    @Published var collaborationRoomID: String?
    @Published var collaborationUser: UserInfo?
    @Published var collaborationParticipants: [UserInfo] = []
    @Published var collaborationChatMessages: [ChatMessage] = []

    @Published var isCollaborationPanelVisible: Bool = false

    @Published var storedProjectRoomID: String?
    private var updateStoredProjectRoomID: ((String?) -> Void)?

    @Published var isCollaborationHost: Bool = false

    var portalDevice: Device?
    var portalBusTask: Task<Void, Never>?

    enum GitHubAuthState: Equatable {
        case signedOut
        case requestingCode(code: String, verifyURL: URL)
        case waitingForApproval
        case authenticated
        case failed(reason: String)
    }

    enum CollaborationStatus: Equatable {
        case disconnected
        case connecting
        case joined(roomID: String)
        case error(message: String)
    }

    struct UserInfo: Identifiable, Hashable {
        let id: String
        let displayName: String
        let avatarURL: String

        static func fromJSON(_ obj: JSONObject) -> UserInfo? {
            guard
                let id = obj["id"] as? String,
                let name = obj["name"] as? String,
                let avatar = obj["avatar"] as? String
            else {
                return nil
            }
            return UserInfo(id: id, displayName: name, avatarURL: avatar)
        }
    }

    struct ChatMessage: Identifiable, Hashable {
        let id = UUID()
        let user: UserInfo
        let text: String
        let timestamp: Date
        let isLocalUser: Bool

        static func fromJSON(_ obj: JSONObject, localUser: UserInfo) -> ChatMessage? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            guard
                let userObj = obj["user"] as? JSONObject,
                let user = UserInfo.fromJSON(userObj),
                let text = obj["text"] as? String,
                let timestampString = obj["timestamp"] as? String,
                let ts = formatter.date(from: timestampString)
            else {
                return nil
            }

            return ChatMessage(
                user: user,
                text: text,
                timestamp: ts,
                isLocalUser: user.id == localUser.id
            )
        }
    }

    private var deviceEventTasks: [String: Task<Void, Never>] = [:]

    let store: ProjectStore

    private var observations: [StoreObservation] = []

    init(store: ProjectStore) {
        self.store = store
        self.engine = Engine(
            store: store,
            coreAgentSource: LumaAgent.coreSource,
            drainAgentSource: LumaAgent.drainSource,
            tracerModuleSource: LumaAgent.tracerSource,
            codeShareModuleSource: LumaAgent.codeShareSource
        )

        githubToken = (try? TokenStore.load(kind: .github)) ?? nil
        Task { await loadCurrentGitHubUser() }
    }

    func configurePersistence() async {
        observations.append(
            store.observeSessions { [weak self] sessions in
                Task { @MainActor in self?.sessions = sessions }
            }
        )
        observations.append(
            store.observeNotebookEntries { [weak self] entries in
                Task { @MainActor in self?.notebookEntries = entries }
            }
        )

        await loadRemoteDevices()
        bindProjectCollaboration()
    }

    func loadRemoteDevices() async {
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
                print("Failed to add remote device \(config.address): \(error)")
            }
        }
    }

    private func loadCurrentGitHubUser() async {
        guard let token = githubToken else {
            currentGitHubUser = nil
            return
        }

        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: req)
            struct Me: Decodable {
                let login: String
                let name: String?
                let avatar_url: String
            }
            let me = try JSONDecoder().decode(Me.self, from: data)

            currentGitHubUser = UserInfo(
                id: me.login,
                displayName: me.name ?? me.login,
                avatarURL: me.avatar_url
            )
        } catch {
            currentGitHubUser = nil
        }
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
        guard
            let node = processNodes.first(where: {
                $0.device.id == device.id && $0.process.pid == pid
            })
        else {
            return
        }

        let coreEvent = LumaCore.RuntimeEvent(
            source: .processOutput(fd: fd),
            payload: .raw(
                message: String(bytes: data, encoding: .utf8) ?? "(\(data.count) bytes on fd \(fd))",
                data: data
            ),
            data: data
        )
        pushEvent(RuntimeEvent(coreEvent: coreEvent, processNode: node))
    }

    func clearEvents() {
        allEvents.removeAll()
        events.removeAll()
        totalEventsReceived = 0
        eventsVersion = 0
        isEventFlushScheduled = false
    }

    func pushEvent(_ event: RuntimeEvent) {
        totalEventsReceived += 1
        allEvents.append(event)

        if allEvents.count > maxEventsInMemory {
            let overflow = allEvents.count - maxEventsInMemory
            allEvents.removeFirst(overflow)
        }

        scheduleEventFlush()
    }

    private func scheduleEventFlush() {
        guard !isEventFlushScheduled else { return }
        isEventFlushScheduled = true

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)

            self?.flushEventsNow()
        }
    }

    private func flushEventsNow() {
        isEventFlushScheduled = false

        let slice = allEvents.suffix(maxEventsVisible)
        events = Array(slice)
        eventsVersion = totalEventsReceived
    }

    func removeNode(_ node: ProcessNodeViewModel) {
        if let idx = processNodes.firstIndex(where: { $0.id == node.id }) {
            let sessionID = node.sessionRecord.id
            addressAnnotationsBySession[sessionID] = [:]
            tracerInstanceIDBySession[sessionID] = nil

            processNodes.remove(at: idx)
            node.stop()
        }
    }

    func addInstrument(
        template: InstrumentTemplate,
        initialConfigJSON: Data,
        for session: LumaCore.ProcessSession
    ) async -> LumaCore.InstrumentInstance {
        let instance = LumaCore.InstrumentInstance(
            sessionID: session.id,
            kind: template.kind,
            sourceIdentifier: template.sourceIdentifier,
            isEnabled: true,
            configJSON: initialConfigJSON
        )
        try? store.save(instance)

        guard let node = processNodes.first(where: { $0.sessionRecord.id == session.id }) else {
            return instance
        }

        node.core.addInstrument(LumaCore.ProcessNode.InstrumentRef(
            id: instance.id, kind: instance.kind,
            sourceIdentifier: instance.sourceIdentifier,
            configJSON: instance.configJSON,
            isEnabled: instance.isEnabled
        ))

        let runtime = InstrumentRuntime(instance: instance, processNode: node)
        node.instruments.append(runtime)

        await loadRuntime(for: runtime, using: template, on: node)

        return instance
    }

    func removeInstrument(
        _ instance: LumaCore.InstrumentInstance,
        from session: LumaCore.ProcessSession
    ) {
        if let node = attachedNode(for: session),
            let idx = node.instruments.firstIndex(where: { $0.instance.id == instance.id })
        {
            let runtime = node.instruments.remove(at: idx)
            node.core.removeInstrument(id: instance.id)
            Task { @MainActor in
                await runtime.dispose()
            }
        }

        try? store.deleteInstrument(id: instance.id)

        if instance.kind == .tracer {
            rebuildAddressDecorations(for: session)
        }
    }

    func setInstrumentEnabled(_ instance: LumaCore.InstrumentInstance, enabled: Bool) async {
        var inst = instance
        inst.isEnabled = enabled
        try? store.save(inst)

        guard let node = processNodes.first(where: { $0.sessionRecord.id == inst.sessionID }) else {
            return
        }

        let runtime: InstrumentRuntime
        if let existingRuntime = node.instruments.first(where: { $0.instance.id == inst.id }) {
            existingRuntime.instance = inst
            runtime = existingRuntime
        } else {
            runtime = InstrumentRuntime(instance: inst, processNode: node)
            node.instruments.append(runtime)
        }

        if enabled {
            guard !runtime.isAttached else { return }

            guard let template = template(for: inst) else { return }
            await loadRuntime(for: runtime, using: template, on: node)
        } else {
            if runtime.isAttached {
                await runtime.dispose()
            }
        }
    }

    func applyInstrumentConfig(
        _ instance: LumaCore.InstrumentInstance,
        data: Data
    ) async {
        var inst = instance
        inst.configJSON = data
        try? store.save(inst)

        let sessionID = inst.sessionID

        if let runtime = runtime(forSessionID: sessionID, instrumentID: inst.id) {
            runtime.instance = inst
            let configObject: JSONObject

            switch instance.kind {
            case .tracer:
                let config = (try? TracerConfig.decode(from: data)) ?? TracerConfig()
                do {
                    _ = try await ensureCompilerWorkspaceReady()
                    let paths = try compilerWorkspacePaths()
                    configObject = try await engine.compileTracerConfig(config, paths: paths)
                } catch {
                    runtime.lastError = "Failed to compile tracer config: \(error)"
                    return
                }

            case .hookPack:
                let config = (try? HookPackConfig.decode(from: data)) ?? HookPackConfig(packId: inst.sourceIdentifier, features: [:])
                configObject = config.toJSON()

            case .codeShare:
                configObject = (try? JSONSerialization.jsonObject(with: data, options: []) as? JSONObject) ?? [:]
            }

            await runtime.applyConfigObject(configObject, rawConfigJSON: data)
        }

        if inst.kind == .tracer, let session = try? store.fetchSession(id: sessionID) {
            rebuildAddressDecorations(for: session)
        }
    }

    private func loadRuntime(
        for runtime: InstrumentRuntime,
        using template: InstrumentTemplate,
        on node: ProcessNodeViewModel
    ) async {
        switch template.kind {
        case .tracer:
            await loadTracerRuntime(for: runtime, on: node)
        case .hookPack:
            await loadHookPackRuntime(for: runtime, template: template, on: node)
        case .codeShare:
            await loadCodeShareRuntime(for: runtime, on: node)
        }
    }

    private func loadTracerRuntime(
        for runtime: InstrumentRuntime,
        on node: ProcessNodeViewModel
    ) async {
        do {
            let instance = runtime.instance
            let config = try TracerConfig.decode(from: instance.configJSON)

            _ = try await ensureCompilerWorkspaceReady()
            let paths = try compilerWorkspacePaths()

            var compiled = try await engine.compileTracerConfig(config, paths: paths)

            var counters: [String: Int] = [:]
            let captures = (try? store.fetchITraceCaptures(sessionID: instance.sessionID)) ?? []
            for capture in captures {
                let key = capture.hookID.uuidString
                counters[key] = max(counters[key] ?? 0, capture.callIndex + 1)
            }
            if !counters.isEmpty {
                compiled["callCounters"] = counters
            }

            try await node.script.exports.loadInstrument(
                JSValue([
                    "instanceId": instance.id.uuidString,
                    "moduleName": "/builtin/tracer.js",
                    "source": LumaAgent.tracerSource,
                    "config": compiled,
                ]))

            runtime.markAttached()

            if let session = try? store.fetchSession(id: instance.sessionID) {
                rebuildAddressDecorations(for: session)
            }
        } catch {
            print("Failed to load tracer instrument: \(error)")
        }
    }

    private func loadHookPackRuntime(
        for runtime: InstrumentRuntime,
        template: InstrumentTemplate,
        on node: ProcessNodeViewModel
    ) async {
        guard let pack = HookPackLibrary.shared.pack(withId: template.sourceIdentifier) else { return }

        do {
            let instance = runtime.instance
            let source = try String(contentsOf: pack.entryURL, encoding: .utf8)

            try await engine.loadHookPackInstrument(
                instanceID: instance.id,
                packID: pack.manifest.id,
                entrySource: source,
                configJSON: instance.configJSON,
                on: node.core
            )

            runtime.markAttached()
        } catch {
            print("Failed to load hook-pack instrument \(template.sourceIdentifier): \(error)")
        }
    }

    private func loadCodeShareRuntime(
        for runtime: InstrumentRuntime,
        on node: ProcessNodeViewModel
    ) async {
        do {
            let instance = runtime.instance
            let cfg = try JSONDecoder().decode(CodeShareConfig.self, from: instance.configJSON)

            try await engine.loadCodeShareInstrument(
                instanceID: instance.id,
                config: cfg,
                configJSON: instance.configJSON,
                on: node.core
            )

            runtime.markAttached()
        } catch {
            print("Failed to load codeshare instrument: \(error)")
        }
    }

    var allInstrumentTemplates: [InstrumentTemplate] {
        tracerTemplates() + hookPackTemplates()
    }

    func template(for instance: LumaCore.InstrumentInstance) -> InstrumentTemplate? {
        switch instance.kind {
        case .tracer, .hookPack:
            return allInstrumentTemplates.first {
                $0.kind == instance.kind && $0.sourceIdentifier == instance.sourceIdentifier
            }
        case .codeShare:
            return codeShareTemplate(for: instance)
        }
    }

    func tracerTemplates() -> [InstrumentTemplate] {
        let icon = InstrumentIcon.system("arrow.triangle.branch")

        let template = InstrumentTemplate(
            id: "tracer",
            kind: .tracer,
            sourceIdentifier: "builtin.tracer",
            displayName: "Tracer",
            icon: icon,
            makeInitialConfigJSON: {
                let config = TracerConfig()
                return try! JSONEncoder().encode(config)
            },
            makeConfigEditor: { jsonBinding, selection in
                let configBinding = Binding<TracerConfig>(
                    get: {
                        (try? TracerConfig.decode(from: jsonBinding.wrappedValue)) ?? TracerConfig()
                    },
                    set: { newValue in
                        jsonBinding.wrappedValue = newValue.encode()
                    }
                )

                return AnyView(
                    TracerConfigView(
                        config: configBinding,
                        workspace: self,
                        selection: selection,
                    )
                )
            },
            makeAddressDecorations: { context, workspace in
                return workspace.addressAnnotationsBySession[context.sessionID]?[context.address]?.decorations ?? []
            },
            makeAddressContextMenuItems: { context, workspace, selection in
                let tracerID = workspace.tracerInstanceIDBySession[context.sessionID]
                let hookID = workspace.addressAnnotationsBySession[context.sessionID]?[context.address]?.tracerHookID

                if let tracerID, let hookID {
                    return [
                        InstrumentAddressMenuItem(
                            title: "Go to Hook",
                            systemImage: "arrow.turn.down.right",
                            role: .normal,
                            action: {
                                selection.wrappedValue = .instrumentComponent(context.sessionID, tracerID, hookID, UUID())
                            }
                        )
                    ]
                } else {
                    return [
                        InstrumentAddressMenuItem(
                            title: "Add Instruction Hook…",
                            systemImage: "pin",
                            role: .normal,
                            action: {
                                Task { @MainActor in
                                    await workspace.addTracerInstructionHook(
                                        sessionID: context.sessionID,
                                        address: context.address,
                                        selection: selection
                                    )
                                }
                            }
                        )
                    ]
                }
            },
            renderEvent: { event, workspace, selection in
                guard case .jsValue(let v) = event.payload,
                    let ev = Engine.parseTracerEvent(from: v)
                else {
                    return AnyView(
                        Text(String(describing: event.payload))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    )
                }

                let messageView: AnyView = {
                    if case .array(_, let elems) = ev.message,
                        elems.count == 1,
                        case .string(let messageText) = elems[0]
                    {
                        return AnyView(
                            Text(messageText)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        )
                    } else {
                        return AnyView(
                            JSInspectValueView(
                                value: ev.message,
                                sessionID: event.processNode.sessionRecord.id,
                                workspace: workspace,
                                selection: selection
                            )
                        )
                    }
                }()

                return AnyView(
                    TracerEventRowView(
                        messageView: messageView,
                        process: event.processNode,
                        backtrace: ev.backtrace,
                        workspace: workspace,
                        selection: selection
                    )
                )
            },
            makeEventContextMenuItems: { event, _, selection in
                guard case .instrument(let instrumentID, _) = event.source,
                    case .jsValue(let v) = event.payload,
                    let ev = Engine.parseTracerEvent(from: v)
                else {
                    return []
                }

                let processNode = event.processNode

                return [
                    InstrumentEventMenuItem(
                        title: "Go to Hook",
                        systemImage: "arrow.turn.down.right",
                        role: .normal
                    ) {
                        selection.wrappedValue = .instrumentComponent(
                            processNode.sessionRecord.id,
                            instrumentID,
                            ev.id,
                            UUID()
                        )
                    }
                ]
            },
            summarizeEvent: { event in
                return String(describing: event.payload)
            },
        )

        return [template]
    }

    private func tracerInstance(for session: LumaCore.ProcessSession) -> LumaCore.InstrumentInstance? {
        let instruments = (try? store.fetchInstruments(sessionID: session.id)) ?? []
        return instruments.first(where: { $0.kind == .tracer })
    }

    private func existingTracerHookID(
        in session: LumaCore.ProcessSession,
        matching address: UInt64
    ) -> UUID? {
        guard let instance = tracerInstance(for: session) else { return nil }
        guard let config = try? TracerConfig.decode(from: instance.configJSON) else { return nil }

        if let node = attachedNode(for: session) {
            for hook in config.hooks {
                if let resolved = try? node.core.resolveSyncIfReady(hook.addressAnchor),
                    resolved == address
                {
                    return hook.id
                }
            }
        }

        let absolute = AddressAnchor.absolute(address)
        return config.hooks.first(where: { $0.addressAnchor == absolute })?.id
    }

    func addTracerInstructionHook(
        sessionID: UUID,
        address: UInt64,
        selection: Binding<SidebarItemID?>
    ) async {
        guard let session = processSession(id: sessionID) else { return }

        let tracer: LumaCore.InstrumentInstance
        if let existing = tracerInstance(for: session) {
            tracer = existing
        } else {
            guard let template = tracerTemplates().first(where: { $0.kind == .tracer }) else { return }
            let initial = template.makeInitialConfigJSON()
            tracer = await addInstrument(template: template, initialConfigJSON: initial, for: session)
        }

        let anchor: AddressAnchor
        if let node = attachedNode(for: session) {
            anchor = node.core.anchor(for: address)
        } else {
            anchor = .absolute(address)
        }

        var config = (try? TracerConfig.decode(from: tracer.configJSON)) ?? TracerConfig()

        if let existingID = config.hooks.first(where: { $0.addressAnchor == anchor })?.id {
            selection.wrappedValue = .instrumentComponent(session.id, tracer.id, existingID, UUID())
            return
        }

        let stub = defaultTracerInstructionStub.replacingOccurrences(of: "INSTRUCTION", with: anchor.displayString)

        let newHook = TracerConfig.Hook(
            id: UUID(),
            displayName: String(format: "0x%llx", address),
            addressAnchor: anchor,
            isEnabled: true,
            code: stub,
        )

        config.hooks.append(newHook)

        let configData = config.encode()
        await applyInstrumentConfig(tracer, data: configData)

        selection.wrappedValue = .instrumentComponent(session.id, tracer.id, newHook.id, UUID())
    }

    func hookPackTemplates() -> [InstrumentTemplate] {
        HookPackLibrary.shared.packs.map { pack in
            let icon: InstrumentIcon
            if let iconMeta = pack.manifest.icon {
                if let file = iconMeta.file {
                    icon = .file(pack.folderURL.appendingPathComponent(file))
                } else if let system = iconMeta.systemName {
                    icon = .system(system)
                } else {
                    icon = .system("puzzlepiece.extension")
                }
            } else {
                icon = .system("puzzlepiece.extension")
            }

            return InstrumentTemplate(
                id: "hook-pack:\(pack.manifest.id)",
                kind: .hookPack,
                sourceIdentifier: pack.manifest.id,
                displayName: pack.manifest.name,
                icon: icon,
                makeInitialConfigJSON: {
                    let defaultEnabled = Dictionary(
                        uniqueKeysWithValues: pack.manifest.features
                            .filter(\.defaultEnabled)
                            .map { ($0.id, FeatureConfig()) }
                    )
                    let config = HookPackConfig(
                        packId: pack.manifest.id,
                        features: defaultEnabled
                    )
                    return try! JSONEncoder().encode(config)
                },
                makeConfigEditor: { jsonBinding, _ in
                    let cfgBinding = Binding<HookPackConfig>(
                        get: {
                            (try? JSONDecoder().decode(HookPackConfig.self, from: jsonBinding.wrappedValue))
                                ?? HookPackConfig(packId: pack.manifest.id, features: [:])
                        },
                        set: { newValue in
                            if let data = try? JSONEncoder().encode(newValue) {
                                jsonBinding.wrappedValue = data
                            }
                        }
                    )

                    return AnyView(
                        HookPackConfigView(
                            manifest: pack.manifest,
                            config: cfgBinding
                        )
                    )
                },
                makeAddressDecorations: { context, workspace in
                    return []
                },
                makeAddressContextMenuItems: { context, workspace, selection in
                    return []
                },
                renderEvent: { event, workspace, selection in
                    guard case .jsValue(let v) = event.payload else {
                        return AnyView(Text(String(describing: event.payload)))
                    }

                    return AnyView(
                        JSInspectValueView(
                            value: v,
                            sessionID: event.processNode.sessionRecord.id,
                            workspace: workspace,
                            selection: selection
                        ))
                },
                makeEventContextMenuItems: { _, _, _ in [] },
                summarizeEvent: { event in
                    return String(describing: event.payload)
                },
            )
        }
    }

    private func codeShareTemplate(for instance: LumaCore.InstrumentInstance) -> InstrumentTemplate? {
        guard
            let cfg = try? JSONDecoder().decode(
                CodeShareConfig.self,
                from: instance.configJSON
            )
        else {
            return nil
        }

        let icon = InstrumentIcon.system("cloud")

        return InstrumentTemplate(
            id: "codeshare:\(instance.sourceIdentifier)",
            kind: .codeShare,
            sourceIdentifier: instance.sourceIdentifier,
            displayName: cfg.name,
            icon: icon,
            makeInitialConfigJSON: {
                try! JSONEncoder().encode(cfg)
            },
            makeConfigEditor: { jsonBinding, _ in
                let cfgBinding = Binding<CodeShareConfig>(
                    get: {
                        (try? JSONDecoder().decode(
                            CodeShareConfig.self,
                            from: jsonBinding.wrappedValue
                        )) ?? cfg
                    },
                    set: { newValue in
                        if let data = try? JSONEncoder().encode(newValue) {
                            jsonBinding.wrappedValue = data
                        }
                    }
                )

                return AnyView(
                    CodeShareConfigView(
                        config: cfgBinding,
                        workspace: self
                    )
                )
            },
            makeAddressDecorations: { context, workspace in
                return []
            },
            makeAddressContextMenuItems: { context, workspace, selection in
                return []
            },
            renderEvent: { event, workspace, selection in
                if case .jsValue(let v) = event.payload {
                    return AnyView(
                        JSInspectValueView(
                            value: v,
                            sessionID: event.processNode.sessionRecord.id,
                            workspace: workspace,
                            selection: selection
                        ))
                }
                return AnyView(Text(String(describing: event.payload)))
            },
            makeEventContextMenuItems: { _, _, _ in [] },
            summarizeEvent: { event in
                String(describing: event.payload)
            }
        )
    }

    func addressDecorations(
        sessionID: UUID,
        address: UInt64
    ) -> [InstrumentAddressDecoration] {
        addressAnnotationsBySession[sessionID]?[address]?.decorations ?? []
    }

    func rebuildAddressDecorations(for session: LumaCore.ProcessSession) {
        guard let tracer = tracerInstance(for: session),
            let node = attachedNode(for: session),
            let config = try? TracerConfig.decode(from: tracer.configJSON)
        else {
            addressAnnotationsBySession[session.id] = [:]
            tracerInstanceIDBySession[session.id] = nil
            return
        }

        tracerInstanceIDBySession[session.id] = tracer.id

        var map: [UInt64: AddressAnnotation] = [:]

        for hook in config.hooks where hook.isEnabled {
            guard let addr = try? node.core.resolveSyncIfReady(hook.addressAnchor) else { continue }

            var ann = map[addr] ?? AddressAnnotation()
            ann.decorations.append(
                InstrumentAddressDecoration(help: "Has instruction hook")
            )
            ann.tracerHookID = hook.id
            map[addr] = ann
        }

        addressAnnotationsBySession[session.id] = map
    }

    func addressContextMenuItems(
        sessionID: UUID,
        address: UInt64,
        selection: Binding<SidebarItemID?>
    ) -> [InstrumentAddressMenuItem] {
        let context = InstrumentAddressContext(sessionID: sessionID, address: address)

        var items: [InstrumentAddressMenuItem] = []
        for template in allInstrumentTemplates {
            items.append(contentsOf: template.makeAddressContextMenuItems(context, self, selection))
        }

        return items
    }

    func spawnAndAttach(
        device: Device,
        sessionRecord: LumaCore.ProcessSession
    ) async {
        guard case .spawn(let config) = sessionRecord.kind else {
            fatalError("spawnAndAttach called with a non-spawn ProcessSession!")
        }

        var s = sessionRecord
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

            await performAttachToProcess(
                device: device,
                using: process,
                sessionRecord: s
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

    func attachToProcess(
        device: Device,
        using process: ProcessDetails,
        sessionRecord: LumaCore.ProcessSession
    ) async {
        await performAttachToProcess(
            device: device,
            using: process,
            sessionRecord: sessionRecord
        )
    }

    private func performAttachToProcess(
        device: Device,
        using process: ProcessDetails,
        sessionRecord: LumaCore.ProcessSession
    ) async {
        var session_ = sessionRecord
        session_.lastKnownPID = process.pid
        session_.detachReason = .applicationRequested
        session_.lastError = nil
        session_.phase = .attaching
        try? store.save(session_)

        do {
            ensureDeviceEventsHooked(for: device)

            let fridaSession = try await device.attach(to: process.pid)

            if var s = try? store.fetchSession(id: session_.id) {
                s.lastAttachedAt = Date()
                try? store.save(s)
            }

            let script = try await fridaSession.createScript(
                LumaAgent.coreSource,
                name: "luma",
                runtime: .auto
            )

            let instruments = (try? store.fetchInstruments(sessionID: session_.id)) ?? []
            let instrumentRefs = instruments.map {
                LumaCore.ProcessNode.InstrumentRef(
                    id: $0.id, kind: $0.kind,
                    sourceIdentifier: $0.sourceIdentifier,
                    configJSON: $0.configJSON,
                    isEnabled: $0.isEnabled
                )
            }

            let coreNode = LumaCore.ProcessNode(
                device: device,
                process: process,
                session: fridaSession,
                script: script,
                instruments: instrumentRefs,
                drainAgentSource: LumaAgent.drainSource
            )
            let node = ProcessNodeViewModel(
                core: coreNode,
                sessionID: session_.id,
                store: store
            )

            let existingCells = (try? store.fetchREPLCells(sessionID: session_.id)) ?? []
            if !existingCells.isEmpty {
                node.markSessionBoundary()
            }

            node.onDestroyed = { [weak self] node, reason in
                guard let self else { return }
                var s = node.sessionRecord
                s.detachReason = reason
                try? self.store.save(s)
                self.removeNode(node)
            }
            node.onModulesSnapshotReady = { [weak self] node in
                guard let self else { return }
                self.rebuildAddressDecorations(for: node.sessionRecord)
            }
            node.eventSink = { [weak self] coreEvent in
                var instrument: InstrumentRuntime?
                if case .instrument(let id, _) = coreEvent.source {
                    instrument = node.instruments.first { $0.id == id }
                }
                let evt = RuntimeEvent(coreEvent: coreEvent, processNode: node, instrument: instrument)
                self?.pushEvent(evt)
            }

            processNodes.append(node)

            await coreNode.waitForScriptEventsSubscription()
            await Task.yield()

            try await script.load()

            await node.fetchAndPersistProcessInfoIfNeeded()

            await coreNode.setupITraceDraining()

            await loadAllPackages(on: node)

            for runtime in node.instruments {
                guard runtime.instance.isEnabled else { continue }
                if let template = template(for: runtime.instance) {
                    await loadRuntime(for: runtime, using: template, on: node)
                }
            }
            node.updateSession { $0.phase = .attached }
        } catch {
            NSLog("[Workspace] attach failed: %@", String(describing: error))
            if var s = try? store.fetchSession(id: session_.id) {
                s.lastError = error.localizedDescription
                s.phase = .idle
                try? store.save(s)
            }
        }
    }

    func resumeSpawnedProcess(node: ProcessNodeViewModel) async {
        let pid = node.sessionRecord.lastKnownPID

        do {
            try await node.device.resume(pid)
            node.updateSession { $0.phase = .attached }
        } catch {
            node.updateSession { $0.lastError = error.localizedDescription }
        }
    }

    func reestablishSession(for sessionRecord: LumaCore.ProcessSession) async {
        var s = sessionRecord
        s.phase = .attaching
        s.detachReason = .applicationRequested
        s.lastError = nil
        try? store.save(s)

        let deviceStore = DeviceListModel(manager: deviceManager)

        while deviceStore.discoveryState == .discovering {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let device = deviceStore.devices.first(where: { $0.id == s.deviceID }) else {
            s.phase = .idle
            try? store.save(s)
            targetPickerContext = .reestablish(
                session: s,
                reason: "The saved device \"\(s.deviceName)\" is not available. Choose a device and target to re-establish this session."
            )
            return
        }

        if case .spawn(_) = s.kind {
            await spawnAndAttach(
                device: device,
                sessionRecord: s
            )
            return
        }

        do {
            let processes = try await device.enumerateProcesses(scope: .full)
            let matches = processes.filter { $0.name == s.processName }

            guard !matches.isEmpty else {
                s.phase = .idle
                try? store.save(s)
                targetPickerContext = .reestablish(
                    session: s,
                    reason:
                        "No running process named \"\(s.processName)\" was found. Choose a new target to re-establish this session."
                )
                return
            }

            let chosen: ProcessDetails
            if let exact = matches.first(where: { $0.pid == s.lastKnownPID }) {
                chosen = exact
            } else if matches.count == 1 {
                chosen = matches[0]
            } else {
                s.phase = .idle
                try? store.save(s)
                targetPickerContext = .reestablish(
                    session: s,
                    reason: "Multiple processes named \"\(s.processName)\" are running. Choose which one to attach to."
                )
                return
            }

            s.deviceName = device.name
            try? store.save(s)

            await performAttachToProcess(
                device: device,
                using: chosen,
                sessionRecord: s
            )
        } catch {
            s.lastError = error.localizedDescription
            s.phase = .idle
            try? store.save(s)
            targetPickerContext = .reestablish(
                session: s,
                reason: "Quick re-establish failed for \"\(s.processName)\". Choose a new target."
            )
        }
    }

    func getOrCreateInsight(
        sessionID: UUID,
        pointer: UInt64,
        kind: LumaCore.AddressInsight.Kind
    ) throws -> LumaCore.AddressInsight {
        guard let node = processNodes.first(where: { $0.sessionRecord.id == sessionID }) else {
            throw LumaCoreError.invalidOperation("No attached process")
        }

        let anchor = node.core.anchor(for: pointer)

        let existing = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        if let match = existing.first(where: { $0.kind == kind && $0.anchor == anchor }) {
            return match
        }

        let insight = LumaCore.AddressInsight(
            sessionID: sessionID,
            title: anchor.displayString,
            kind: kind,
            anchor: anchor
        )
        try? store.save(insight)
        return insight
    }

    private func processSession(id sessionID: UUID) -> LumaCore.ProcessSession? {
        processNodes.first { $0.sessionRecord.id == sessionID }?.sessionRecord
    }

    private func attachedNode(for session: LumaCore.ProcessSession) -> ProcessNodeViewModel? {
        processNodes.first(where: { $0.sessionRecord.id == session.id })
    }

    private func runtime(forSessionID sessionID: UUID, instrumentID: UUID) -> InstrumentRuntime? {
        guard let node = processNodes.first(where: { $0.sessionRecord.id == sessionID }) else { return nil }
        return node.instruments.first(where: { $0.instance.id == instrumentID })
    }
}
