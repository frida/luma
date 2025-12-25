import Combine
import CryptoKit
import Frida
import SwiftData
import SwiftUI

@MainActor
final class Workspace: ObservableObject {
    let deviceManager = DeviceManager()

    @Published var processNodes: [ProcessNode] = []

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

    @Published var targetPickerContext: TargetPickerContext?

    let packageManager = PackageManager()
    let packageOps = PackageOperationQueue()
    var compilerWorkspaceRoot: URL?
    var packageBundles: [String: String] = [:]
    var packageBundlesDirty: Bool = true
    @Published var lastCompilerDiagnostics: [String] = []

    @Published var isAuthSheetPresented: Bool = false
    @Published var authState: GitHubAuthState = .signedOut
    @Published var currentGitHubUser: UserInfo?
    @Published var githubToken: String? {
        didSet {
            Task { await loadCurrentGitHubUser() }
        }
    }

    var collaborationState: ProjectCollaborationState!
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

    var modelContext: ModelContext!

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

    init() {
        githubToken = (try? TokenStore.load(kind: .github)) ?? nil
        Task { await loadCurrentGitHubUser() }
    }

    func configurePersistence(modelContext: ModelContext) async {
        self.modelContext = modelContext

        await loadRemoteDevices()
        bindProjectCollaboration()
    }

    func loadRemoteDevices() async {
        for config in try! modelContext.fetch(FetchDescriptor<RemoteDeviceConfig>()) {
            let device = try! await deviceManager.addRemoteDevice(
                address: config.address,
                certificate: config.certificate,
                origin: config.origin,
                token: config.token,
                keepaliveInterval: config.keepaliveInterval
            )
            config.runtimeDeviceID = device.id
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
                    self.handleDeviceOutput(
                        device: device,
                        data: data,
                        fd: fd,
                        pid: pid
                    )

                case .lost:
                    self.handleDeviceLost(device)
                    return

                default:
                    break
                }
            }
        }
    }

    private func handleDeviceOutput(
        device: Device,
        data: [UInt8],
        fd: Int,
        pid: UInt
    ) {
        guard
            let node = processNodes.first(where: {
                $0.device.id == device.id && $0.process.pid == pid
            })
        else {
            return
        }

        let text =
            String(bytes: data, encoding: .utf8)
            ?? "(\(data.count) bytes on fd \(fd))"

        let evt = RuntimeEvent(
            source: .processOutput(process: node, fd: fd),
            payload: text,
            data: data
        )
        pushEvent(evt)
    }

    private func handleDeviceLost(_ device: Device) {
        deviceEventTasks[device.id]?.cancel()
        deviceEventTasks[device.id] = nil
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

    func removeNode(_ node: ProcessNode) {
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
        for session: ProcessSession
    ) async -> InstrumentInstance {
        let instance = InstrumentInstance(
            kind: template.kind,
            sourceIdentifier: template.sourceIdentifier,
            isEnabled: true,
            configJSON: initialConfigJSON,
            session: session
        )

        session.instruments.append(instance)
        modelContext!.insert(instance)

        guard let node = processNodes.first(where: { $0.sessionRecord == session }) else {
            return instance
        }

        let runtime = InstrumentRuntime(instance: instance, processNode: node)
        node.instruments.append(runtime)

        await loadRuntime(for: runtime, using: template, on: node)

        return instance
    }

    func removeInstrument(
        _ instance: InstrumentInstance,
        from session: ProcessSession
    ) {
        if let node = attachedNode(for: session),
            let idx = node.instruments.firstIndex(where: { $0.instance == instance })
        {
            let runtime = node.instruments.remove(at: idx)
            Task { @MainActor in
                await runtime.dispose()
            }
        }

        if let idx = session.instruments.firstIndex(where: { $0.id == instance.id }) {
            session.instruments.remove(at: idx)
        }

        if instance.kind == .tracer {
            rebuildAddressDecorations(for: session)
        }

        modelContext.delete(instance)
    }

    func setInstrumentEnabled(_ instance: InstrumentInstance, enabled: Bool) async {
        instance.isEnabled = enabled

        let session = instance.session

        guard let node = processNodes.first(where: { $0.sessionRecord == session }) else {
            return
        }

        let runtime: InstrumentRuntime
        if let existingRuntime = node.instruments.first(where: { $0.instance == instance }) {
            runtime = existingRuntime
        } else {
            runtime = InstrumentRuntime(instance: instance, processNode: node)
            node.instruments.append(runtime)
        }

        if enabled {
            guard !runtime.isAttached else { return }

            guard let template = template(for: instance) else { return }
            await loadRuntime(for: runtime, using: template, on: node)
        } else {
            if runtime.isAttached {
                await runtime.dispose()
            }
        }
    }

    func applyInstrumentConfig(
        _ instance: InstrumentInstance,
        data: Data
    ) async {
        instance.configJSON = data

        let session = instance.session

        if let runtime = runtime(for: session, instrumentID: instance.id) {
            await runtime.applyConfigJSON(data)
        }

        if instance.kind == .tracer {
            rebuildAddressDecorations(for: session)
        }
    }

    private func loadRuntime(
        for runtime: InstrumentRuntime,
        using template: InstrumentTemplate,
        on node: ProcessNode
    ) async {
        switch template.kind {
        case .tracer:
            await loadTracerRuntime(for: runtime, template: template, on: node)
        case .hookPack:
            await loadHookPackRuntime(for: runtime, template: template, on: node)
        case .codeShare:
            await loadCodeShareRuntime(for: runtime, template: template, on: node)
        }
    }

    private func loadTracerRuntime(
        for runtime: InstrumentRuntime,
        template: InstrumentTemplate,
        on node: ProcessNode
    ) async {
        do {
            let instance = runtime.instance

            let config = try TracerConfig.decode(from: instance.configJSON)

            try await node.script.exports.loadInstrument(
                JSValue([
                    "instanceId": instance.id.uuidString,
                    "moduleName": "/builtin/tracer.js",
                    "source": LumaAgent.tracerSource,
                    "config": config.toJSON(),
                ]))

            runtime.markAttached()

            rebuildAddressDecorations(for: instance.session)
        } catch {
            print("Failed to load tracer instrument: \(error)")
        }
    }

    private func loadHookPackRuntime(
        for runtime: InstrumentRuntime,
        template: InstrumentTemplate,
        on node: ProcessNode
    ) async {
        guard let pack = HookPackLibrary.shared.pack(withId: template.sourceIdentifier) else { return }

        do {
            let instance = runtime.instance

            let source = try String(contentsOf: pack.entryURL, encoding: .utf8)
            let config = try InstrumentConfigCodec.decode(HookPackConfig.self, from: instance.configJSON)

            try await node.script.exports.loadInstrument(
                JSValue([
                    "instanceId": instance.id.uuidString,
                    "moduleName": hookPackModuleName(packId: pack.manifest.id, source: source),
                    "source": source,
                    "config": config.toJSON(),
                ]))

            runtime.markAttached()
        } catch {
            print("Failed to load hook-pack instrument \(template.sourceIdentifier): \(error)")
        }
    }

    private func hookPackModuleName(packId: String, source: String) -> String {
        let data = Data(source.utf8)
        let digest = SHA256.hash(data: data)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        return "/hookpacks/\(packId)/\(hashHex).js"
    }

    private func loadCodeShareRuntime(
        for runtime: InstrumentRuntime,
        template: InstrumentTemplate,
        on node: ProcessNode
    ) async {
        do {
            let instance = runtime.instance

            let cfg = try JSONDecoder().decode(
                CodeShareConfig.self,
                from: instance.configJSON)

            let configObject: Any
            if instance.configJSON.isEmpty {
                configObject = [:]
            } else {
                configObject = try JSONSerialization.jsonObject(
                    with: instance.configJSON,
                    options: [])
            }

            try await node.script.exports.loadInstrument(
                JSValue([
                    "instanceId": instance.id.uuidString,
                    "moduleName": codeShareModuleName(
                        slug: cfg.project?.slug ?? cfg.name,
                        source: cfg.source
                    ),
                    "source": LumaAgent.codeShareSource,
                    "config": configObject,
                ]))

            runtime.markAttached()
        } catch {
            print("Failed to load codeshare instrument \(template.sourceIdentifier): \(error)")
        }
    }

    private func codeShareModuleName(slug: String, source: String) -> String {
        let data = Data(source.utf8)
        let digest = SHA256.hash(data: data)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        return "/codeshare/\(slug)/\(hashHex).js"
    }

    var allInstrumentTemplates: [InstrumentTemplate] {
        tracerTemplates() + hookPackTemplates()
    }

    func template(for instance: InstrumentInstance) -> InstrumentTemplate? {
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
                guard let v = event.payload as? JSInspectValue,
                    let ev = Workspace.parseTracerEvent(from: v)
                else {
                    return AnyView(
                        Text(String(describing: event.payload))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    )
                }

                return AnyView(
                    Group {
                        if case .string(let messageText) = ev.message {
                            Text(messageText)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            JSInspectValueView(
                                value: ev.message,
                                sessionID: event.process.sessionRecord.id,
                                workspace: workspace,
                                selection: selection
                            )
                        }
                    }
                )
            },
            makeEventContextMenuItems: { event, _, selection in
                guard case .instrument(let process, let instrument) = event.source,
                    let v = event.payload as? JSInspectValue,
                    let ev = Workspace.parseTracerEvent(from: v)
                else {
                    return []
                }

                return [
                    InstrumentEventMenuItem(
                        title: "Go to Hook",
                        systemImage: "arrow.turn.down.right",
                        role: .normal
                    ) {
                        selection.wrappedValue = .instrumentComponent(
                            process.sessionRecord.id,
                            instrument.instance.id,
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

    private func tracerInstance(for session: ProcessSession) -> InstrumentInstance? {
        session.instruments.first(where: { $0.kind == .tracer })
    }

    private func existingTracerHookID(
        in session: ProcessSession,
        matching address: UInt64
    ) -> UUID? {
        guard let instance = tracerInstance(for: session) else { return nil }
        guard let config = try? TracerConfig.decode(from: instance.configJSON) else { return nil }

        if let node = attachedNode(for: session) {
            for hook in config.hooks {
                if let resolved = try? node.resolveSyncIfReady(hook.addressAnchor),
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

        let tracer: InstrumentInstance
        if let existing = tracerInstance(for: session) {
            tracer = existing
        } else {
            guard let template = tracerTemplates().first(where: { $0.kind == .tracer }) else { return }
            let initial = template.makeInitialConfigJSON()
            tracer = await addInstrument(template: template, initialConfigJSON: initial, for: session)
        }

        let anchor: AddressAnchor
        if let node = attachedNode(for: session) {
            anchor = node.anchor(for: address)
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

    static func parseTracerEvent(from value: JSInspectValue) -> (type: String, id: UUID, message: JSInspectValue)? {
        guard case .object(_, let properties) = value else {
            return nil
        }

        var typeString: String?
        var idValue: UUID?
        var messageValue: JSInspectValue?

        for property in properties {
            guard case .string(let keyString) = property.key else {
                return nil
            }

            switch keyString {
            case "type":
                if case .string(let t) = property.value {
                    typeString = t
                }

            case "id":
                if case .string(let rawId) = property.value,
                    let uuid = UUID(uuidString: rawId)
                {
                    idValue = uuid
                }

            case "message":
                messageValue = property.value

            default:
                break
            }
        }

        guard let type = typeString,
            let id = idValue,
            let message = messageValue
        else {
            return nil
        }

        return (type, id, message)
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
                    let configBinding = Binding<HookPackConfig>(
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
                            config: configBinding
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
                    guard let v = event.payload as? JSInspectValue else {
                        return AnyView(Text(String(describing: event.payload)))
                    }

                    return AnyView(
                        JSInspectValueView(
                            value: v,
                            sessionID: event.process.sessionRecord.id,
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

    private func codeShareTemplate(for instance: InstrumentInstance) -> InstrumentTemplate? {
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
                if let v = event.payload as? JSInspectValue {
                    return AnyView(
                        JSInspectValueView(
                            value: v,
                            sessionID: event.process.sessionRecord.id,
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

    func rebuildAddressDecorations(for session: ProcessSession) {
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
            guard let addr = try? node.resolveSyncIfReady(hook.addressAnchor) else { continue }

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
        sessionRecord: ProcessSession,
        modelContext: ModelContext
    ) async {
        guard case .spawn(let config) = sessionRecord.kind else {
            fatalError("spawnAndAttach called with a non-spawn ProcessSession!")
        }

        sessionRecord.phase = .attaching
        defer {
            if sessionRecord.phase == .attaching {
                sessionRecord.phase = .idle
            }
        }
        sessionRecord.detachReason = .applicationRequested
        sessionRecord.lastError = nil

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
                sessionRecord.lastError = Error.processNotFound("Spawned pid \(pid) not found in enumerateProcesses(pids:)")
                return
            }

            sessionRecord.deviceName = device.name

            await performAttachToProcess(
                device: device,
                using: process,
                sessionRecord: sessionRecord,
                modelContext: modelContext
            )

            if config.autoResume {
                try await device.resume(pid)
                sessionRecord.phase = .attached
            } else {
                sessionRecord.phase = .awaitingInitialResume
            }
        } catch {
            sessionRecord.lastError = error as? Error ?? .invalidOperation(error.localizedDescription)
        }
    }

    func attachToProcess(
        device: Device,
        using process: ProcessDetails,
        sessionRecord: ProcessSession,
        modelContext: ModelContext
    ) async {
        sessionRecord.phase = .attaching
        defer {
            if sessionRecord.phase == .attaching {
                sessionRecord.phase = .idle
            }
        }

        await performAttachToProcess(
            device: device,
            using: process,
            sessionRecord: sessionRecord,
            modelContext: modelContext
        )

        sessionRecord.phase = .attached
    }

    private func performAttachToProcess(
        device: Device,
        using process: ProcessDetails,
        sessionRecord: ProcessSession,
        modelContext: ModelContext
    ) async {
        do {
            sessionRecord.lastKnownPID = process.pid
            sessionRecord.detachReason = .applicationRequested
            sessionRecord.lastError = nil

            ensureDeviceEventsHooked(for: device)

            let session = try await device.attach(to: process.pid)

            sessionRecord.lastAttachedAt = Date()

            let script = try await session.createScript(
                LumaAgent.coreSource,
                name: "luma",
                runtime: .auto
            )

            let node = ProcessNode(
                device: device,
                process: process,
                session: session,
                script: script,
                sessionRecord: sessionRecord,
                modelContext: modelContext
            )
            if !sessionRecord.replCells.isEmpty {
                node.markSessionBoundary()
            }
            node.onDestroyed = { [weak self] node, reason in
                sessionRecord.detachReason = reason
                self?.removeNode(node)
            }
            node.onModulesSnapshotReady = { [weak self] node in
                guard let self else { return }
                self.rebuildAddressDecorations(for: node.sessionRecord)
            }
            node.eventSink = { [weak self] evt in
                self?.pushEvent(evt)
            }

            processNodes.append(node)

            await node.waitForScriptEventsSubscription()
            await Task.yield()

            try await script.load()

            await loadAllPackages(on: node)

            for runtime in node.instruments {
                guard runtime.instance.isEnabled else { continue }
                if let template = template(for: runtime.instance) {
                    await loadRuntime(for: runtime, using: template, on: node)
                }
            }
        } catch {
            sessionRecord.lastError = error as? Error ?? .invalidOperation(error.localizedDescription)
        }
    }

    func resumeSpawnedProcess(node: ProcessNode) async {
        let pid = node.sessionRecord.lastKnownPID

        do {
            try await node.device.resume(pid)
            node.sessionRecord.phase = .attached
        } catch {
            node.sessionRecord.lastError = error as? Error ?? .invalidOperation(error.localizedDescription)
        }
    }

    func reestablishSession(for sessionRecord: ProcessSession, modelContext: ModelContext) async {
        sessionRecord.phase = .attaching
        defer {
            if sessionRecord.phase == .attaching {
                sessionRecord.phase = .idle
            }
        }
        sessionRecord.detachReason = .applicationRequested
        sessionRecord.lastError = nil

        let deviceStore = DeviceListModel(manager: deviceManager)

        while deviceStore.discoveryState == .discovering {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let device = deviceStore.devices.first(where: { $0.id == sessionRecord.deviceID }) else {
            targetPickerContext = .reestablish(
                session: sessionRecord,
                reason:
                    "The saved device “\(sessionRecord.deviceName)” is not available. Choose a device and target to re-establish this session."
            )
            return
        }

        if case .spawn(_) = sessionRecord.kind {
            await spawnAndAttach(
                device: device,
                sessionRecord: sessionRecord,
                modelContext: modelContext
            )
            return
        }

        do {
            let processes = try await device.enumerateProcesses(scope: .full)
            let matches = processes.filter { $0.name == sessionRecord.processName }

            guard !matches.isEmpty else {
                targetPickerContext = .reestablish(
                    session: sessionRecord,
                    reason:
                        "No running process named “\(sessionRecord.processName)” was found. Choose a new target to re-establish this session."
                )
                return
            }

            let chosen: ProcessDetails
            if let exact = matches.first(where: { $0.pid == sessionRecord.lastKnownPID }) {
                chosen = exact
            } else if matches.count == 1 {
                chosen = matches[0]
            } else {
                targetPickerContext = .reestablish(
                    session: sessionRecord,
                    reason: "Multiple processes named “\(sessionRecord.processName)” are running. Choose which one to attach to."
                )
                return
            }

            sessionRecord.deviceName = device.name

            await performAttachToProcess(
                device: device,
                using: chosen,
                sessionRecord: sessionRecord,
                modelContext: modelContext
            )
        } catch {
            sessionRecord.lastError = error as? Error ?? .invalidOperation(error.localizedDescription)
            targetPickerContext = .reestablish(
                session: sessionRecord,
                reason: "Quick re-establish failed for “\(sessionRecord.processName)”. Choose a new target."
            )
        }
    }

    func getOrCreateInsight(
        sessionID: UUID,
        pointer: UInt64,
        kind: AddressInsight.Kind
    ) throws -> AddressInsight {
        let session = fetchSession(id: sessionID)

        guard let node = processNodes.first(where: { $0.sessionRecord.id == sessionID }) else {
            throw Error.invalidOperation(
                "Cannot resolve address anchor without an attached process"
            )
        }

        let anchor = node.anchor(for: pointer)

        if let existing = session.insights.first(where: { $0.kind == kind && $0.anchor == anchor }) {
            return existing
        }

        return insertInsight(session: session, kind: kind, anchor: anchor)
    }

    private func fetchSession(id sessionID: UUID) -> ProcessSession {
        return processSession(id: sessionID)!
    }

    private func processSession(id sessionID: UUID) -> ProcessSession? {
        try? modelContext.fetch(
            FetchDescriptor<ProcessSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
        ).first
    }

    private func attachedNode(for session: ProcessSession) -> ProcessNode? {
        processNodes.first(where: { $0.sessionRecord == session })
    }

    private func runtime(for session: ProcessSession, instrumentID: UUID) -> InstrumentRuntime? {
        guard let node = attachedNode(for: session) else { return nil }
        return node.instruments.first(where: { $0.instance.id == instrumentID })
    }

    private func insertInsight(
        session: ProcessSession,
        kind: AddressInsight.Kind,
        anchor: AddressAnchor
    ) -> AddressInsight {
        let insight = AddressInsight(
            title: anchor.displayString,
            kind: kind,
            anchor: anchor
        )

        insight.session = session
        session.insights.append(insight)
        modelContext.insert(insight)

        return insight
    }
}

typealias JSONObject = [String: Any]
