import Foundation
import LumaCore
import SwiftyPharo

enum PharoPlaygroundError: LocalizedError {
    case noImage

    var errorDescription: String? {
        "No Pharo image found. Set LUMA_PHARO_IMAGE to a SwiftyPharo.image, or bundle it with the app."
    }
}

extension PharoRuntime {
    /// Boots the bundled image the first time a pane needs it, then waits for the
    /// bridge to answer. The macOS app has its own richer bootstrap; this is the
    /// minimum the GTK playground needs.
    @MainActor
    func startPlayground(for engine: Engine) async throws {
        guard Self.bootDidStart else { throw PharoPlaygroundError.noImage }
        try await runningState()
    }

    private static let bootDidStart: Bool = {
        guard let image = imageURL else { return false }
        PharoRuntime.shared.boot(image: image)
        return true
    }()

    private static var imageURL: URL? {
        if let path = ProcessInfo.processInfo.environment["LUMA_PHARO_IMAGE"] {
            return URL(fileURLWithPath: path)
        }
        return Bundle.module.url(forResource: "SwiftyPharo", withExtension: "image")
    }
}
