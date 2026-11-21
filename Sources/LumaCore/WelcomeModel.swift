import Foundation
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
        public let pictureContentType: String
        public let pictureData: Data
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

    private let portal = PortalConnection.shared
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
        if let existing = fetchTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await performFetch()
        }
        fetchTask = task
        await task.value
        fetchTask = nil
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
                labsState = .failed(message: error.localizedDescription)
            }
        }
    }

    private func fetchSummaries(token: String) async throws -> [LabSummary] {
        let lease = try await portal.retain(token: token) { _ in }
        do {
            let reply = try await lease.request(to: "/labs", type: ".list")
            await lease.release()
            let items = (reply.payload["labs"] as? [JSONObject]) ?? []
            return items.compactMap { LabSummary.fromJSON($0, payloadData: reply.data) }
        } catch {
            await lease.release()
            throw error
        }
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

        guard let pictureObj = obj["picture"] as? JSONObject,
              let pictureContentType = pictureObj["content_type"] as? String,
              let payloadData,
              let offset = pictureObj["offset"] as? Int,
              let length = pictureObj["length"] as? Int,
              offset >= 0, offset + length <= payloadData.count
        else { return nil }
        let pictureData = Data(payloadData[offset..<offset + length])

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
