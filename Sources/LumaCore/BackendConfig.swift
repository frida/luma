import Foundation

public enum BackendConfig {
    public static let portalAddress = localOverride("LUMA_PORTAL_ADDRESS") ?? "portal.luma.frida.re:27042"
    public static let inviteLinkBase = "https://luma.frida.re/l/"
    public static let pushEnrollURL = "https://luma.frida.re/push-enroll"
    public static let storeCatalogURL = URL(string: localOverride("LUMA_STORE_CATALOG_URL") ?? "https://luma.frida.re/api/store/")!
    public static let privacyPolicyURL = URL(string: "https://luma.frida.re/privacy")!

    public static func labID(fromInviteLink url: URL) -> String? {
        guard url.absoluteString.hasPrefix(inviteLinkBase) else { return nil }
        let code = url.absoluteString.dropFirst(inviteLinkBase.count)
            .prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return code.isEmpty ? nil : String(code)
    }

    public static let certificate: String? = {
        if localOverride("LUMA_PORTAL_ADDRESS") != nil {
            return localOverride("LUMA_PORTAL_CERTIFICATE").map { try! String(contentsOfFile: $0, encoding: .utf8) }
        }
        guard let url = Bundle.module.url(forResource: "LumaPortal", withExtension: "pem") else {
            fatalError("LumaPortal.pem not found in LumaCore resources")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read LumaPortal.pem: \(error)")
        }
    }()

    private static func localOverride(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}
