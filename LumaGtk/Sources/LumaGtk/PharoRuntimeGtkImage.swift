import Foundation
import LumaCore
import SwiftyPharo

extension PharoRuntime {
    /// Boots the bundled image the first time a pane needs it, then waits for the
    /// bridge to answer. The macOS app has its own richer bootstrap; this is the
    /// minimum the GTK playground needs.
    @MainActor
    func startPlayground(for engine: Engine) async throws {
        _ = Self.bootedImage
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
