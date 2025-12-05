import Foundation

enum BackendConfig {
    static let portalAddress = "luma.frida.re:443"

    static let certificate: String = {
        guard let url = Bundle.main.url(forResource: "ISRGRootX1", withExtension: "pem") else {
            fatalError("ISRGRootX1.pem not found in bundle")
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read ISRGRootX1.pem: \(error)")
        }
    }()
}
