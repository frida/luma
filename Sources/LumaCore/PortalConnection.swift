import Foundation
import Frida

@MainActor
public final class PortalConnection {
    public static let shared = PortalConnection(
        deviceManager: .shared,
        address: BackendConfig.portalAddress,
        certificate: BackendConfig.certificate
    )

    public enum Event {
        case notification(Notification)
        case detached
    }

    public struct Notification {
        public let from: String
        public let type: String
        public let payload: JSONObject
        public let data: [UInt8]?
    }

    public struct Reply: @unchecked Sendable {
        public let payload: JSONObject
        public let data: [UInt8]?
    }

    @MainActor
    public final class Lease {
        public let welcome: JSONObject

        fileprivate let onEvent: @MainActor (Event) -> Void
        private let connection: PortalConnection

        fileprivate init(connection: PortalConnection, welcome: JSONObject, onEvent: @escaping @MainActor (Event) -> Void) {
            self.welcome = welcome
            self.onEvent = onEvent
            self.connection = connection
        }

        public func request(to path: String, type: String, payload: JSONObject = [:], data: [UInt8]? = nil) async throws -> Reply {
            try await withCheckedThrowingContinuation { continuation in
                connection.send(to: path, type: type, payload: payload, data: data, from: self, completion: .resuming(continuation))
            }
        }

        func request(
            to path: String,
            type: String,
            payload: JSONObject = [:],
            data: [UInt8]? = nil,
            onReply: @escaping (Result<Reply, AuthFailure>) -> Void
        ) {
            connection.send(to: path, type: type, payload: payload, data: data, from: self, completion: .calling(onReply))
        }

        public func notify(to path: String, type: String, payload: JSONObject = [:], data: [UInt8]? = nil) {
            connection.post(to: path, type: type, payload: payload, data: data, from: self)
        }

        public func release() async {
            await connection.release(self)
        }
    }

    private enum Phase {
        case idle
        case connecting(Task<Void, Swift.Error>)
        case connected(Device, welcome: JSONObject)
        case closing(Task<Void, Never>)
    }

    private enum Greeting {
        case pending
        case awaited(CheckedContinuation<Void, Swift.Error>)
        case received(JSONObject)
        case lost
    }

    private struct PendingReply {
        let lease: Lease
        let completion: Completion
    }

    @MainActor
    fileprivate enum Completion {
        case calling((Result<Reply, AuthFailure>) -> Void)
        case resuming(CheckedContinuation<Reply, Swift.Error>)

        func deliver(_ result: Result<Reply, AuthFailure>) {
            switch self {
            case .calling(let onReply):
                onReply(result)
            case .resuming(let continuation):
                continuation.resume(with: result.mapError { $0 })
            }
        }

        func abandon() {
            if case .resuming(let continuation) = self {
                continuation.resume(throwing: PortalConnection.detachedFailure)
            }
        }
    }

    private static let detachedFailure = AuthFailure(domain: "portal", code: "detached", message: "Bus detached")

    private let deviceManager: DeviceManager
    private let address: String
    private let certificate: String?
    private var phase: Phase = .idle
    private var generation = 0
    private var greeting: Greeting = .pending
    private var leases: [Lease] = []
    private var pendingReplies: [String: PendingReply] = [:]
    private var nextRequestID = 0
    private var busTask: Task<Void, Never>?

    public init(deviceManager: DeviceManager, address: String, certificate: String?) {
        self.deviceManager = deviceManager
        self.address = address
        self.certificate = certificate
    }

    public func retain(token: String, onEvent: @escaping @MainActor (Event) -> Void) async throws -> Lease {
        let welcome = try await connect(token: token, generation: generation)
        let lease = Lease(connection: self, welcome: welcome, onEvent: onEvent)
        leases.append(lease)
        return lease
    }

    public func disconnect() async {
        generation += 1
        if case .connecting(let attempt) = phase {
            _ = try? await attempt.value
        }
        if case .connected = phase {
            dropConnection()
        }
        if case .closing(let teardown) = phase {
            await teardown.value
        }
    }

    fileprivate func send(
        to path: String,
        type: String,
        payload: JSONObject,
        data: [UInt8]?,
        from lease: Lease,
        completion: Completion
    ) {
        guard case .connected(let device, _) = phase, isActive(lease) else {
            completion.abandon()
            return
        }
        nextRequestID += 1
        let id = "r\(nextRequestID)"
        pendingReplies[id] = PendingReply(lease: lease, completion: completion)
        var envelope = Self.envelope(to: path, type: type, payload: payload)
        envelope["id"] = id
        device.bus.post(envelope, data: data)
    }

    fileprivate func post(to path: String, type: String, payload: JSONObject, data: [UInt8]?, from lease: Lease) {
        guard case .connected(let device, _) = phase, isActive(lease) else { return }
        device.bus.post(Self.envelope(to: path, type: type, payload: payload), data: data)
    }

    fileprivate func release(_ lease: Lease) async {
        guard let index = leases.firstIndex(where: { $0 === lease }) else { return }
        leases.remove(at: index)
        abandonReplies { $0.lease === lease }
        if leases.isEmpty {
            await beginClosing().value
        }
    }

    private func connect(token: String, generation startingGeneration: Int) async throws -> JSONObject {
        while true {
            guard generation == startingGeneration else { throw Self.detachedFailure }
            switch phase {
            case .idle:
                phase = .connecting(Task { try await self.open(token: token) })
            case .connecting(let attempt):
                try await attempt.value
            case .connected(_, let welcome):
                return welcome
            case .closing(let teardown):
                await teardown.value
            }
        }
    }

    private func open(token: String) async throws {
        greeting = .pending
        do {
            let device = try await deviceManager.addRemoteDevice(
                address: address,
                certificate: certificate,
                origin: nil,
                token: token,
                keepaliveInterval: nil
            )
            listen(to: device.bus)
            try await device.bus.attach()
            let welcome = try await awaitWelcome()
            phase = .connected(device, welcome: welcome)
        } catch {
            busTask?.cancel()
            busTask = nil
            try? await deviceManager.removeRemoteDevice(address: address)
            phase = .idle
            throw error
        }
    }

    private func listen(to bus: Bus) {
        let events = bus.events
        busTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func awaitWelcome() async throws -> JSONObject {
        if case .pending = greeting {
            try await withCheckedThrowingContinuation { greeting = .awaited($0) }
        }
        guard case .received(let welcome) = greeting else { throw Self.detachedFailure }
        return welcome
    }

    private func handle(_ event: Bus.Event) {
        switch event {
        case .detached:
            connectionLost()
        case .message(let message, let data):
            guard let envelope = message as? JSONObject, let type = envelope["type"] as? String else {
                connectionLost()
                return
            }
            if type == "+result" || type == "+error" {
                settleReply(to: envelope, type: type, data: data)
                return
            }
            guard let from = envelope["from"] as? String else { return }
            let payload = (envelope["payload"] as? JSONObject) ?? [:]
            if from == "/session" && type == "+welcome" {
                greet(with: payload)
            } else {
                fanOut(.notification(Notification(from: from, type: type, payload: payload, data: data)))
            }
        }
    }

    private func settleReply(to envelope: JSONObject, type: String, data: [UInt8]?) {
        guard let id = envelope["id"] as? String, let pending = pendingReplies.removeValue(forKey: id) else { return }
        if type == "+result" {
            pending.completion.deliver(.success(Reply(payload: (envelope["payload"] as? JSONObject) ?? [:], data: data)))
        } else {
            let error = envelope["error"] as? JSONObject
            let code = error?["code"] as? String ?? "unknown"
            let message = error?["message"] as? String ?? "request failed"
            pending.completion.deliver(.failure(AuthFailure(domain: "portal", code: code, message: message)))
        }
    }

    private func greet(with welcome: JSONObject) {
        let awaited = greeting
        greeting = .received(welcome)
        if case .awaited(let continuation) = awaited {
            continuation.resume()
        }
    }

    private func fanOut(_ event: Event) {
        for lease in leases {
            lease.onEvent(event)
        }
    }

    private func connectionLost() {
        switch phase {
        case .connecting:
            loseGreeting()
        case .connected:
            dropConnection()
        case .idle, .closing:
            break
        }
    }

    private func loseGreeting() {
        let awaited = greeting
        greeting = .lost
        if case .awaited(let continuation) = awaited {
            continuation.resume(throwing: Self.detachedFailure)
        }
    }

    private func dropConnection() {
        let dropped = leases
        beginClosing()
        for lease in dropped {
            lease.onEvent(.detached)
        }
    }

    @discardableResult
    private func beginClosing() -> Task<Void, Never> {
        leases.removeAll()
        abandonReplies { _ in true }
        busTask?.cancel()
        busTask = nil
        let teardown = Task {
            try? await self.deviceManager.removeRemoteDevice(address: self.address)
            self.phase = .idle
        }
        phase = .closing(teardown)
        return teardown
    }

    private func abandonReplies(where isAbandoned: (PendingReply) -> Bool) {
        let abandoned = pendingReplies.filter { isAbandoned($0.value) }
        for id in abandoned.keys {
            pendingReplies.removeValue(forKey: id)
        }
        for reply in abandoned.values {
            reply.completion.abandon()
        }
    }

    private func isActive(_ lease: Lease) -> Bool {
        leases.contains { $0 === lease }
    }

    private static func envelope(to path: String, type: String, payload: JSONObject) -> JSONObject {
        var envelope: JSONObject = ["to": path, "type": type]
        if !payload.isEmpty {
            envelope["payload"] = payload
        }
        return envelope
    }
}
