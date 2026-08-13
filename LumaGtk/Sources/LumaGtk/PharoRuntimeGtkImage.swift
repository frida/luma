import Foundation
import LumaCore
import SwiftyPharo

extension PharoRuntime {
    /// Boots the bundled image before GTK, WebKit and cairo reserve their large
    /// virtual regions, so the Spur heap still finds its expected base free.
    /// Returns at once; the image loads on its own thread.
    static func bootBundledImage() {
        _ = bootedImage
    }

    /// Waits for the already-booting image to answer. The macOS app has its own
    /// richer bootstrap; this is the minimum the GTK playground needs.
    @MainActor
    func startPlayground(for engine: Engine) async throws {
        Self.bootBundledImage()
        try await runningState()
    }

    /// The Makefile stages this into the resource bundle before building, so its
    /// absence is a broken build rather than a condition to handle.
    private static let bootedImage: URL = {
        let image = Bundle.module.url(forResource: "SwiftyPharo", withExtension: "image", subdirectory: "pharo-image")!
        PharoRuntime.shared.boot(image: image)
        return image
    }()
}
