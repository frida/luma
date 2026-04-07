import Foundation

public enum BackendConfig {
    public static let portalAddress = "luma.frida.re:443"

    public static let certificate: String = {
        guard let url = Bundle.module.url(forResource: "ISRGRootX1", withExtension: "pem") else {
            fatalError("ISRGRootX1.pem not found in LumaCore resources")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read ISRGRootX1.pem: \(error)")
        }
    }()
}
