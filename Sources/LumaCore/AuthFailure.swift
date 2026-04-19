import Foundation
import Frida

/// Wire-format sibling of `luma-server`'s `AuthFailure`. The portal's
/// authentication delegate packs this JSON envelope into the thrown error
/// message so clients can tell an auth rejection (domain == "auth") apart
/// from a transient upstream issue (domain == "github").
public struct AuthFailure: Sendable, Decodable, Swift.Error {
    public let domain: String
    public let code: String
    public let message: String

    public init(domain: String, code: String, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public var isAuthRejection: Bool { domain == "auth" }

    public static func fromError(_ error: any Swift.Error) -> AuthFailure? {
        guard let fridaError = error as? Frida.Error else { return nil }
        let raw: String
        switch fridaError {
        case .invalidArgument(let message):
            raw = message
        default:
            return nil
        }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AuthFailure.self, from: data)
    }
}
