import Combine
import Foundation

final class GitHubAuthenticator: ObservableObject {
    static let shared = GitHubAuthenticator()

    private let clientID = "Ov23lij2uZMOQCj4TMkv"

    private var currentTask: Task<Void, Never>?

    struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    struct AccessTokenResponse: Decodable {
        let access_token: String?
        let token_type: String?
        let scope: String?
        let error: String?
    }

    @MainActor
    func beginSignIn(workspace: Workspace) async {
        currentTask?.cancel()

        currentTask = Task { @MainActor in
            workspace.authState = .waitingForApproval
            do {
                let codeResp = try await requestDeviceCode()
                workspace.authState = .requestingCode(
                    code: codeResp.user_code,
                    verifyURL: URL(string: codeResp.verification_uri)!
                )

                let token = try await pollForToken(
                    deviceCode: codeResp.device_code,
                    interval: codeResp.interval,
                    expiresIn: codeResp.expires_in
                )

                try TokenStore.save(token, kind: .github)
                workspace.githubToken = token

                workspace.authState = .authenticated
            } catch is CancellationError {
                workspace.authState = .signedOut
            } catch {
                workspace.authState = .failed(reason: error.localizedDescription)
            }
        }
    }

    @MainActor
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
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
            if Date() >= deadline { throw GitHubAuthError.invalidToken }

            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            try Task.checkCancellation()

            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.httpBody = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(
                using: .utf8)
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(AccessTokenResponse.self, from: data)

            if let error = resp.error {
                if error == "authorization_pending" { continue }
                if error == "slow_down" {
                    delay += 5
                    continue
                }
                if error == "expired_token" { throw GitHubAuthError.invalidToken }
                throw GitHubAuthError.invalidToken
            }

            guard let token = resp.access_token else { throw GitHubAuthError.invalidToken }
            return token
        }
    }
}

enum GitHubAuthError: Error {
    case invalidToken
    case invalidResponse
    case decodingFailed
}
