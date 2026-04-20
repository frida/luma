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

    /// Marker the server prefixes its base64-encoded JSON envelope with.
    /// Must match `LumaServer.AuthFailure.marker`.
    private static let marker = "luma-auth:"
    private static let base64Alphabet: Set<Character> = {
        var set = Set<Character>("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return set
    }()

    public static func fromError(_ error: any Swift.Error) -> AuthFailure? {
        // The portal's auth delegate tags its JSON envelope with a
        // `luma-auth:<base64>` sentinel. Any wrapping layers (Frida's
        // client-side transport re-stringifies the error one or more
        // times on its way up) can't corrupt the base64 alphabet, so we
        // just scan for the marker and decode the payload up to the
        // first non-base64 byte.
        let text: String
        if let fridaError = error as? Frida.Error {
            text = fridaError.description
        } else {
            text = String(describing: error)
        }

        guard let markerRange = text.range(of: marker) else { return nil }
        let tail = text[markerRange.upperBound...]
        let base64End = tail.firstIndex { !base64Alphabet.contains($0) } ?? tail.endIndex
        let encoded = String(tail[..<base64End])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(AuthFailure.self, from: data)
    }
}
