import Foundation
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable
@MainActor
public final class GitHubAuth {
    public enum State: Equatable, Sendable {
        case signedOut
        case requestingCode(code: String, verifyURL: URL)
        case waitingForApproval
        case authenticated
        case failed(reason: String)
    }

    public enum AuthError: Error {
        case invalidToken
        case invalidResponse
    }

    public private(set) var state: State = .signedOut
    public private(set) var token: String?
    public private(set) var currentUser: CollaborationSession.UserInfo?
    public var isPresentingSignIn: Bool = false

    private let clientID = "Ov23lij2uZMOQCj4TMkv"
    private let service = "re.frida.Luma"
    private let account = "github"
    private let tokenStore: TokenStore
    private var signInTask: Task<Void, Never>?
    private var pendingTokenWaiters: [CheckedContinuation<String?, Never>] = []

    init(tokenStore: TokenStore) {
        self.tokenStore = tokenStore
    }

    public func loadPersistedToken() async {
        token = try? await tokenStore.get(service: service, account: account)
        await refreshCurrentUser()
    }

    public func beginSignIn() {
        signInTask?.cancel()
        signInTask = Task { @MainActor in
            state = .waitingForApproval
            do {
                let codeResp = try await requestDeviceCode()
                guard let url = URL(string: codeResp.verification_uri) else {
                    throw AuthError.invalidResponse
                }
                state = .requestingCode(code: codeResp.user_code, verifyURL: url)

                let newToken = try await pollForToken(
                    deviceCode: codeResp.device_code,
                    interval: codeResp.interval,
                    expiresIn: codeResp.expires_in
                )

                try? await tokenStore.set(service: service, account: account, token: newToken)
                token = newToken
                await refreshCurrentUser()
                state = .authenticated
                dismissSignIn()
            } catch is CancellationError {
                state = .signedOut
            } catch {
                state = .failed(reason: error.localizedDescription)
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        state = .signedOut
        isPresentingSignIn = false
    }

    public func resetState() {
        state = .signedOut
    }

    public func requestToken() async -> String? {
        if let token { return token }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            pendingTokenWaiters.append(cont)
            if !isPresentingSignIn {
                isPresentingSignIn = true
                beginSignIn()
            }
        }
    }

    public func dismissSignIn() {
        isPresentingSignIn = false
        let waiters = pendingTokenWaiters
        pendingTokenWaiters.removeAll()
        for cont in waiters { cont.resume(returning: token) }
    }

    public func signOut() async {
        try? await tokenStore.delete(service: service, account: account)
        token = nil
        currentUser = nil
        state = .signedOut
    }

    private func refreshCurrentUser() async {
        guard let token else {
            currentUser = nil
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
            currentUser = CollaborationSession.UserInfo(
                id: me.login,
                name: me.name ?? me.login,
                avatarURL: URL(string: me.avatar_url)
            )
        } catch {
            currentUser = nil
        }
    }

    private struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    private struct AccessTokenResponse: Decodable {
        let access_token: String?
        let error: String?
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.httpBody = "client_id=\(clientID)&scope=read:user".data(using: .utf8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var delay = Double(interval)

        while true {
            try Task.checkCancellation()
            if Date() >= deadline { throw AuthError.invalidToken }

            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try Task.checkCancellation()

            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.httpBody = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
                .data(using: .utf8)
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(AccessTokenResponse.self, from: data)

            if let error = resp.error {
                if error == "authorization_pending" { continue }
                if error == "slow_down" {
                    delay += 5
                    continue
                }
                throw AuthError.invalidToken
            }

            guard let token = resp.access_token else { throw AuthError.invalidToken }
            return token
        }
    }
}
