import Foundation

public enum BackendConfig {
    public static let portalAddress = "portal.luma.frida.re:27042"
    public static let inviteLinkBase = "https://luma.frida.re/l/"

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
