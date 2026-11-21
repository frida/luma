import Foundation

public enum BackendConfig {
    public static let portalAddress = "portal.luma.frida.re:27042"
    public static let inviteLinkBase = "https://luma.frida.re/l/"
    public static let pushEnrollURL = "https://luma.frida.re/push-enroll"
    public static let storeCatalogURL = URL(string: "https://luma.frida.re/api/store/")!

    public static func labID(fromInviteLink url: URL) -> String? {
        guard url.absoluteString.hasPrefix(inviteLinkBase) else { return nil }
        let code = url.absoluteString.dropFirst(inviteLinkBase.count)
            .prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return code.isEmpty ? nil : String(code)
    }

    public static let certificate: String = {
        guard let url = Bundle.module.url(forResource: "LumaPortal", withExtension: "pem") else {
            fatalError("LumaPortal.pem not found in LumaCore resources")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read LumaPortal.pem: \(error)")
        }
    }()
}
