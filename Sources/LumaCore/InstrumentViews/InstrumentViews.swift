import Foundation
import Observation
import SwiftyPharo

@Observable
@MainActor
public final class InstrumentViews {
    public struct Key: Hashable, Sendable {
        public let instanceID: UUID
        public let widget: String

        public init(instanceID: UUID, widget: String) {
            self.instanceID = instanceID
            self.widget = widget
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case checking
        case awaitingApproval(HostCodeOrigin)
        case starting
        case running(generation: Int)
        case failed(String)
    }

    private enum Ending {
        case closing
        case abandoning
    }

    public private(set) var phases: [Key: Phase] = [:]

    @ObservationIgnored private weak var engine: Engine?
    @ObservationIgnored let trust: HostCodeTrust
    @ObservationIgnored private var demand: [Key: Int] = [:]
    @ObservationIgnored private var views: [Key: RunningView] = [:]
    @ObservationIgnored private var viewsByID: [String: RunningView] = [:]
    @ObservationIgnored private var heldEvents: [Key: [WidgetViewPayload]] = [:]
    @ObservationIgnored private var heldRefusals: [Key: String] = [:]
    @ObservationIgnored private var spawnWatchers: [Key: [UUID: AsyncStream<PharoObject>.Continuation]] = [:]
    @ObservationIgnored private var codeFiles: [String: [CustomInstrumentFile]] = [:]
    @ObservationIgnored private var loadedCode: Set<String> = []
    @ObservationIgnored private var operations: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    public static let stoppedTitle = "The view stopped"
    public static let restartLabel = "Restart"

    static let heldEventLimit = 64
    static let messageDataLimit = 1024 * 1024

    init(engine: Engine, catalogURL: URL) {
        self.engine = engine
        trust = HostCodeTrust(catalogURL: catalogURL)
    }

    public func phase(of key: Key) -> Phase {
        phases[key] ?? .idle
    }

    public func show(_ key: Key) {
        demand[key, default: 0] += 1
        startIfWanted(key)
    }

    public func hide(_ key: Key) {
        demand[key, default: 1] -= 1
    }

    public func allow(_ key: Key) {
        guard let engine, let target = engine.viewTarget(for: key), let hostCode = target.hostCode else { return }
        trust.approve(hostCode.digest)
        for (other, phase) in phases {
            guard case .awaitingApproval = phase, engine.viewTarget(for: other)?.def.id == target.def.id else { continue }
            phases[other] = .idle
            startIfWanted(other)
        }
    }

    public func restart(_ key: Key) {
        perform(key) { [weak self] in
            await self?.teardown(key, .closing)
            self?.phases[key] = .idle
        }
        startIfWanted(key)
    }

    public func declarations(of key: Key) async throws -> [PharoViewDeclaration] {
        try JSONDecoder().decode([PharoViewDeclaration].self, from: try await request(.views, of: key))
    }

    public func items(of key: Key, view: String, from: Int, count: Int, filter: String?) async throws -> PharoItemsPage {
        let page = try await request(.items(view: view, from: from, count: count, filter: filter), of: key)
        return try JSONDecoder().decode(PharoItemsPage.self, from: page)
    }

    public func drill(into key: Key, view: String, index: Int, filter: String?) async throws -> PharoObject {
        try JSONDecoder().decode(PharoObject.self, from: try await request(.send(view: view, index: index, filter: filter), of: key))
    }

    public func spawns(of key: Key) -> AsyncStream<PharoObject> {
        let (spawned, continuation) = AsyncStream<PharoObject>.makeStream()
        let watcher = UUID()
        spawnWatchers[key, default: [:]][watcher] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.spawnWatchers[key]?[watcher] = nil }
        }
        return spawned
    }

    func start() {
        guard let engine else { return }
        let updates = engine.widgetUpdates
        updatesTask = Task { [weak self] in
            for await update in updates {
                self?.route(update)
            }
        }
    }

    func reconcile(with instruments: [UUID: [InstrumentInstance]]) {
        let enabled = Set(instruments.values.joined().filter { $0.state == .enabled }.map(\.id))
        for key in Set(views.keys).union(phases.keys) where !enabled.contains(key.instanceID) {
            perform(key) { [weak self] in
                await self?.teardown(key, .closing)
                self?.phases[key] = nil
                self?.heldEvents[key] = nil
                self?.heldRefusals[key] = nil
            }
        }
    }

    func reload(customInstrument defID: UUID) {
        guard let engine else { return }
        for key in Set(views.keys).union(phases.keys) {
            guard let target = engine.viewTarget(for: key), target.def.id == defID else { continue }
            let running = views[key]
            let isCurrent = running.map { $0.digest == target.hostCode?.digest && $0.className == target.config.className } ?? false
            guard !isCurrent else { continue }
            perform(key) { [weak self] in
                await self?.teardown(key, .closing)
                self?.phases[key] = .idle
            }
            startIfWanted(key)
        }
    }

    func stopAll() async {
        updatesTask?.cancel()
        for key in views.keys {
            await teardown(key, .closing)
        }
        phases.removeAll()
    }


    func noteLocalEdit(from previous: HostCode?, to next: HostCode?) {
        trust.noteLocalEdit(from: previous, to: next)
    }

    func answer(_ operation: String, _ request: [String: Any]) async throws -> Any {
        if operation == "view_code" {
            let code: String = try argument("code", of: request)
            return (codeFiles[code] ?? []).map { ["path": $0.path, "source": $0.content] }
        }
        let view = try runningView(of: request)
        switch operation {
        case "view_inbox":
            return PharoPulledResult { [weak self, view] in
                await view.inbox.next().map { self?.json(of: $0, for: view) ?? NSNull() }
            }
        case "view_reply":
            let number: Int = try argument("request", of: request)
            if let message = request["error"] as? String {
                view.pending.removeValue(forKey: number)?.resume(throwing: InstrumentViewError.failed(message))
            } else {
                let result = try JSONSerialization.data(withJSONObject: request["result"] ?? NSNull(), options: [.fragmentsAllowed])
                view.pending.removeValue(forKey: number)?.resume(returning: result)
            }
            return NSNull()
        case "view_failed":
            let message: String = try argument("message", of: request)
            fail(view, message)
            return NSNull()
        case "view_canvas":
            let scene: Int = try argument("scene", of: request)
            listen(to: scene, for: view)
            return NSNull()
        case "view_changed":
            if case .running(let generation) = phases[view.key] {
                phases[view.key] = .running(generation: generation + 1)
            }
            return NSNull()
        case "view_can_send":
            return engine?.canSendViewMessage(from: view.key) ?? false
        case "view_send":
            return try send(request, from: view)
        case "view_spawn":
            let described = try JSONSerialization.data(withJSONObject: try argument("object", of: request) as [String: Any])
            return spawn(try JSONDecoder().decode(PharoObject.self, from: described), from: view)
        default:
            throw PharoAsyncBridgeError.unknownOperation(operation)
        }
    }

    private func startIfWanted(_ key: Key) {
        guard demand[key, default: 0] > 0 else { return }
        perform(key) { [weak self] in
            guard let self, views[key] == nil, phase(of: key) == .idle else { return }
            await launch(key)
        }
    }

    private func launch(_ key: Key) async {
        guard let engine, let target = engine.viewTarget(for: key) else {
            phases[key] = .failed("The widget's instrument is gone.")
            return
        }
        guard let hostCode = target.hostCode else {
            phases[key] = .failed("The instrument has no Smalltalk (.st files) to show this widget with.")
            return
        }

        phases[key] = .checking
        if case .ask(let origin) = await trust.decide(hostCode, ofCustomInstrument: target.def.id) {
            phases[key] = .awaitingApproval(origin)
            return
        }

        phases[key] = .starting
        let code = "\(target.def.id.uuidString)/\(target.instance.sessionID.uuidString)/\(hostCode.digest)"
        let view = RunningView(key: key, code: code, digest: hostCode.digest, className: target.config.className)
        view.inbox.abandoned = { [weak self, weak view] in
            guard let self, let view else { return }
            fail(view, "The view stopped answering.")
        }
        do {
            let runtime = try await engine.pharo.started()
            try await load(hostCode, as: code, into: runtime)
            views[key] = view
            viewsByID[view.id] = view
            view.inbox.push(.open(ViewOpening(code: code, className: target.config.className, widgetName: target.widgetName)))
            view.inbox.push(.state(engine.widgetState(instanceID: key.instanceID, widget: key.widget).view))
            for event in heldEvents.removeValue(forKey: key) ?? [] {
                view.inbox.push(.event(event))
            }
            try await runtime.release(try await runtime.evaluate("LumaInstrumentView open: '\(view.id)'"))
            if phases[key] == .starting {
                phases[key] = .running(generation: 0)
            }
            if let refusal = heldRefusals.removeValue(forKey: key) {
                fail(view, refusal)
            }
        } catch {
            phases[key] = .failed(error.localizedDescription)
            await teardown(key, .abandoning)
        }
    }

    private func fail(_ view: RunningView, _ message: String) {
        guard views[view.key] === view else { return }
        phases[view.key] = .failed(message)
        view.abandonRequests()
        perform(view.key) { [weak self] in
            await self?.teardown(view.key, .abandoning)
        }
    }

    private func load(_ hostCode: HostCode, as code: String, into runtime: PharoRuntime) async throws {
        guard !loadedCode.contains(code) else { return }
        codeFiles[code] = hostCode.files
        let report = try await runtime.evaluate("LumaInstrumentCode load: '\(code)'")
        try await runtime.release(report)
        guard report.printString.isEmpty else { throw InstrumentViewError.failed(report.printString) }
        loadedCode.insert(code)
    }

    private func teardown(_ key: Key, _ ending: Ending) async {
        guard let view = views[key] else { return }
        if ending == .closing, case .running = phases[key] {
            _ = try? await request(.close, of: view)
        }
        views[key] = nil
        viewsByID[view.id] = nil
        view.inbox.close()
        for scene in view.scenes {
            CanvasInputListeners.stopListening(to: scene)
        }
        view.abandonRequests()
        await engine?.pharo.stopRun(view.owner)
        PharoBlobRegistry.shared.releaseAll(lentTo: view.owner)
        await forgetUnusedCode()
    }

    private func forgetUnusedCode() async {
        guard let engine else { return }
        let inUse = Set(views.values.map(\.code))
        for code in loadedCode.subtracting(inUse) {
            loadedCode.remove(code)
            codeFiles[code] = nil
            if let forgotten = try? await engine.pharo.runtime.evaluate("LumaInstrumentCode forget: '\(code)'") {
                try? await engine.pharo.runtime.release(forgotten)
            }
        }
    }

    private func request(_ asked: ViewRequest, of key: Key) async throws -> Data {
        guard let view = views[key], case .running = phases[key] else { throw InstrumentViewError.failed("The view is not running.") }
        return try await request(asked, of: view)
    }

    private func request(_ asked: ViewRequest, of view: RunningView) async throws -> Data {
        let number = view.nextRequest
        view.nextRequest += 1
        return try await withCheckedThrowingContinuation { continuation in
            view.pending[number] = continuation
            view.inbox.push(.request(number, asked))
        }
    }

    private func route(_ update: WidgetUpdate) {
        let key = Key(instanceID: update.instanceID, widget: update.widget)
        switch update.kind {
        case .viewState(let state):
            views[key]?.inbox.push(.state(state))
        case .viewEvent(let event):
            if let view = views[key] {
                view.inbox.push(.event(event))
            } else if engine?.isViewWidget(key) == true {
                heldEvents[key, default: []].append(event)
                heldEvents[key] = heldEvents[key]?.suffix(Self.heldEventLimit)
            }
        case .viewRefused(let message):
            refuse(message, for: key)
        case .clear:
            heldEvents[key] = nil
            views[key]?.inbox.push(.state(nil))
        case .snapshot(let state):
            views[key]?.inbox.push(.state(state.view))
        default:
            break
        }
    }

    private func refuse(_ message: String, for key: Key) {
        guard let view = views[key] else {
            heldRefusals[key] = message
            return
        }
        fail(view, message)
    }

    private func json(of item: ViewItem, for view: RunningView) -> Any {
        switch item {
        case .open(let opening):
            return [
                "kind": "open",
                "code": opening.code,
                "class": opening.className,
                "instance": view.key.instanceID.uuidString,
                "widget": view.key.widget,
                "widgetName": opening.widgetName,
            ]
        case .state(let state):
            return ["kind": "state", "value": state?.payload.value ?? NSNull(), "data": lend(state?.payload.data, to: view)]
        case .event(let event):
            return ["kind": "event", "value": event.value, "data": lend(event.data, to: view)]
        case .input(let event):
            return ["kind": "input", "event": event.pharoJSON]
        case .request(let number, let asked):
            var body = asked.json
            body["request"] = number
            return body
        }
    }

    private func lend(_ data: SharedBytes?, to view: RunningView) -> Any {
        guard let data else { return NSNull() }
        return ["blob": PharoBlobRegistry.shared.lend(data, to: view.owner), "size": data.count]
    }

    private func listen(to scene: Int, for view: RunningView) {
        view.scenes.insert(scene)
        CanvasInputListeners.listen(to: scene) { [weak view] event in
            view?.inbox.push(.input(event))
        }
    }

    private func send(_ request: [String: Any], from view: RunningView) throws -> Bool {
        guard let engine else { return false }
        let data = (request["data"] as? [Any]).flatMap { span -> SharedBytes? in
            guard let blob = span.first as? Int else { return nil }
            return PharoBlobRegistry.shared.bytes(blob)
        }
        let json: String = try argument("json", of: request)
        let payload: WidgetViewPayload
        do throws(WidgetViewRefusal) {
            payload = try WidgetViewPayload(json: json, data: data).checking(atMost: Self.messageDataLimit)
        } catch {
            throw InstrumentViewError.failed("The message was refused: \(error.message)")
        }
        return engine.sendViewMessage(payload, from: view.key)
    }

    private func spawn(_ object: PharoObject, from view: RunningView) -> Bool {
        let deliveries = (spawnWatchers[view.key] ?? [:]).values.map { $0.yield(object) }
        return deliveries.contains { if case .enqueued = $0 { true } else { false } }
    }

    private func runningView(of request: [String: Any]) throws -> RunningView {
        let id: String = try argument("view", of: request)
        guard let view = viewsByID[id] else { throw InstrumentViewError.failed("The view stopped.") }
        return view
    }

    private func perform(_ key: Key, _ operation: @escaping @MainActor () async -> Void) {
        let previous = operations[key]
        operations[key] = Task {
            await previous?.value
            await operation()
        }
    }

    private func argument<T>(_ name: String, of request: [String: Any]) throws -> T {
        guard let value = request[name] as? T else { throw PharoAsyncBridgeError.missingArgument(name) }
        return value
    }
}

public enum InstrumentViewError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

@MainActor
final class RunningView {
    let key: InstrumentViews.Key
    let owner = UUID()
    let code: String
    let digest: String
    let className: String
    let inbox = ViewInbox()
    var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    var nextRequest = 1
    var scenes: Set<Int> = []

    init(key: InstrumentViews.Key, code: String, digest: String, className: String) {
        self.key = key
        self.code = code
        self.digest = digest
        self.className = className
    }

    var id: String {
        owner.uuidString
    }

    func abandonRequests() {
        for continuation in pending.values {
            continuation.resume(throwing: InstrumentViewError.failed("The view stopped."))
        }
        pending.removeAll()
    }
}

enum ViewItem: Sendable {
    case open(ViewOpening)
    case state(WidgetViewState?)
    case event(WidgetViewPayload)
    case input(CanvasInputEvent)
    case request(Int, ViewRequest)
}

struct ViewOpening: Sendable {
    let code: String
    let className: String
    let widgetName: String
}

enum ViewRequest: Sendable {
    case views
    case items(view: String, from: Int, count: Int, filter: String?)
    case send(view: String, index: Int, filter: String?)
    case close

    var json: [String: Any] {
        switch self {
        case .views:
            return ["kind": "views"]
        case .items(let view, let from, let count, let filter):
            return ["kind": "items", "view": view, "from": from, "count": count, "filter": filter ?? NSNull()]
        case .send(let view, let index, let filter):
            return ["kind": "send", "view": view, "index": index, "filter": filter ?? NSNull()]
        case .close:
            return ["kind": "close"]
        }
    }
}

@MainActor
final class ViewInbox {
    var abandoned: (@MainActor () -> Void)?

    private var items: [ViewItem] = []
    private var waiter: CheckedContinuation<ViewItem?, Never>?
    private var state = State.open

    private enum State {
        case open
        case closed
    }

    func push(_ item: ViewItem) {
        guard state == .open else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
            return
        }
        coalesce(item)
    }

    func next() async -> ViewItem? {
        if !items.isEmpty {
            return items.removeFirst()
        }
        guard state == .open else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor in
                self.close()
                self.abandoned?()
            }
        }
    }

    func close() {
        state = .closed
        items.removeAll()
        waiter?.resume(returning: nil)
        waiter = nil
    }

    private func coalesce(_ item: ViewItem) {
        switch (item, items.last) {
        case (.state, _):
            if let at = items.firstIndex(where: { if case .state = $0 { true } else { false } }) {
                items[at] = item
            } else {
                items.append(item)
            }
        case (.input(let event), .input(let pending)?) where event.kind == pending.kind && Self.mergeable.contains(event.kind):
            items[items.count - 1] = .input(Self.merged(pending, event))
        default:
            items.append(item)
        }
    }

    private static let mergeable: Set<CanvasInputEvent.Kind> = [.move, .scroll, .zoom]

    private static func merged(_ earlier: CanvasInputEvent, _ later: CanvasInputEvent) -> CanvasInputEvent {
        var merged = later
        merged.dx += earlier.dx
        merged.dy += earlier.dy
        merged.factor *= earlier.factor
        return merged
    }
}
