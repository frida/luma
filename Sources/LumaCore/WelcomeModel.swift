import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class WelcomeModel {
    public struct LabSummary: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let role: String
        public let joinedAt: String
        public let lastSeenAt: String
        public let memberCount: Int
        public let onlineCount: Int
        public let owner: CollaborationSession.UserInfo?
        public let pictureContentType: String?
        public let pictureData: Data?
    }

    public enum LabsState: Sendable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    public let gitHubAuth: GitHubAuth
    public private(set) var labs: [LabSummary] = []
    public private(set) var labsState: LabsState = .idle

    private let portalAddress = BackendConfig.portalAddress
    private let portalCertificate = BackendConfig.certificate
    private let deviceManager = DeviceManager()
    private var fetchTask: Task<Void, Never>?
    private var didBootstrap = false

    public init(tokenStore: TokenStore? = nil, dataDirectory: URL) {
        self.gitHubAuth = GitHubAuth(
            tokenStore: tokenStore ?? defaultTokenStore(dataDirectory: dataDirectory)
        )
    }

    public func bootstrap() async {
        if didBootstrap { return }
        didBootstrap = true
        await gitHubAuth.loadPersistedToken()
        if gitHubAuth.token != nil {
            await refreshLabs()
        }
    }

    public func signIn() {
        labsState = .idle
        labs = []
        guard !gitHubAuth.isPresentingSignIn else { return }
        gitHubAuth.isPresentingSignIn = true
        gitHubAuth.beginSignIn()
    }

    public func signOut() async {
        fetchTask?.cancel()
        fetchTask = nil
        await gitHubAuth.signOut()
        labs = []
        labsState = .idle
    }

    public func refreshLabs() async {
        fetchTask?.cancel()
        let task = Task { @MainActor in
            await performFetch()
        }
        fetchTask = task
        await task.value
    }

    private func performFetch() async {
        guard let token = gitHubAuth.token else {
            labsState = .idle
            return
        }
        labsState = .loading
        do {
            let summaries = try await fetchSummaries(token: token)
            if Task.isCancelled { return }
            labs = summaries
            labsState = .loaded
        } catch is CancellationError {
            return
        } catch {
            if let failure = AuthFailure.fromError(error), failure.isAuthRejection {
                await gitHubAuth.signOut()
                labsState = .failed(message: failure.message)
            } else {
                labsState = .failed(message: String(describing: error))
            }
        }
    }

    private func fetchSummaries(token: String) async throws -> [LabSummary] {
        let device = try await deviceManager.addRemoteDevice(
            address: portalAddress,
            certificate: portalCertificate,
            origin: nil,
            token: token,
            keepaliveInterval: nil
        )
        defer {
            Task { try? await deviceManager.removeRemoteDevice(address: portalAddress) }
        }

        let listener = LabListListener()
        let busTask = Task { @MainActor in
            for await event in device.bus.events {
                if Task.isCancelled { return }
                listener.handle(event)
            }
        }
        defer { busTask.cancel() }

        try await device.bus.attach()
        return try await listener.requestList(via: device.bus)
    }
}

extension WelcomeModel.LabSummary {
    static func fromJSON(_ obj: JSONObject, payloadData: [UInt8]?) -> WelcomeModel.LabSummary? {
        guard let id = obj["id"] as? String,
              let title = obj["title"] as? String,
              let role = obj["role"] as? String,
              let joinedAt = obj["joined_at"] as? String,
              let lastSeenAt = obj["last_seen_at"] as? String
        else { return nil }
        let memberCount = (obj["member_count"] as? Int) ?? 0
        let onlineCount = (obj["online_count"] as? Int) ?? 0
        let owner = (obj["owner"] as? JSONObject).flatMap(CollaborationSession.UserInfo.fromJSON)

        var pictureContentType: String?
        var pictureData: Data?
        if let pictureObj = obj["picture"] as? JSONObject,
           let contentType = pictureObj["content_type"] as? String {
            pictureContentType = contentType
            if let payloadData,
               let offset = pictureObj["offset"] as? Int,
               let length = pictureObj["length"] as? Int,
               offset >= 0, offset + length <= payloadData.count {
                pictureData = Data(payloadData[offset..<offset + length])
            }
        }

        return WelcomeModel.LabSummary(
            id: id,
            title: title,
            role: role,
            joinedAt: joinedAt,
            lastSeenAt: lastSeenAt,
            memberCount: memberCount,
            onlineCount: onlineCount,
            owner: owner,
            pictureContentType: pictureContentType,
            pictureData: pictureData
        )
    }
}

@MainActor
private final class LabListListener {
    private let requestId = "welcome-list-labs"
    private var continuation: CheckedContinuation<[WelcomeModel.LabSummary], Swift.Error>?

    func requestList(via bus: Bus) async throws -> [WelcomeModel.LabSummary] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[WelcomeModel.LabSummary], Swift.Error>) in
            continuation = cont
            bus.post(["to": "/labs", "type": ".list", "id": requestId], data: nil)
        }
    }

    func handle(_ event: Bus.Event) {
        switch event {
        case .detached:
            resume(throwing: AuthFailure(domain: "portal", code: "detached", message: "Bus detached"))

        case .message(let anyValue, let data):
            guard let dict = anyValue as? JSONObject,
                  let id = dict["id"] as? String,
                  id == requestId,
                  let type = dict["type"] as? String
            else { return }
            if type == "+result" {
                let payload = (dict["payload"] as? JSONObject) ?? [:]
                let items = (payload["labs"] as? [JSONObject]) ?? []
                resume(returning: items.compactMap {
                    WelcomeModel.LabSummary.fromJSON($0, payloadData: data)
                })
            } else if type == "+error" {
                let err = (dict["error"] as? JSONObject) ?? [:]
                let code = (err["code"] as? String) ?? "unknown"
                let message = (err["message"] as? String) ?? "request failed"
                resume(throwing: AuthFailure(domain: "portal", code: code, message: message))
            }
        }
    }

    private func resume(returning value: [WelcomeModel.LabSummary]) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func resume(throwing error: Swift.Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
