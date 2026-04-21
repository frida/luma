import Foundation

/// Holds the APNs device token that `registerForRemoteNotifications()`
/// hands back via the app delegate, so `Engine` can forward it to the
/// portal when an authenticated session is established.
///
/// The token is per-installation, not per-user, so we keep a single
/// shared instance. `Engine` subscribes once and re-pushes on every
/// authenticated `+welcome` so a signed-in user always has this device's
/// APNs subscription on file.
@MainActor
public final class APNsRegistration {
    public static let shared = APNsRegistration()

    public private(set) var deviceToken: Data?
    public private(set) var lastError: String?

    private var observers: [(Data) -> Void] = []

    private init() {}

    public func setToken(_ data: Data) {
        deviceToken = data
        lastError = nil
        for observer in observers { observer(data) }
    }

    public func setError(_ message: String) {
        lastError = message
    }

    public func observe(_ handler: @escaping (Data) -> Void) {
        observers.append(handler)
        if let deviceToken { handler(deviceToken) }
    }

    public var deviceTokenHex: String? {
        deviceToken?.map { String(format: "%02x", $0) }.joined()
    }

    /// Which APNs endpoint the token is valid against: sandbox for
    /// debug builds (signed with `aps-environment = development`) and
    /// production for release builds (`aps-environment = production`).
    public static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
