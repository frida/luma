import Foundation
import SwiftyPharo

extension PharoRuntime {
    /// Every view that needs the runtime calls this; only the first one starts
    /// the VM, and the rest wait for it.
    func startBundledImage() async throws {
        _ = Self.bootedImage
        try await runningState()
    }

    /// The `Stage Pharo image` build phase puts this in the bundle, so its
    /// absence is a broken build rather than a condition to handle.
    private static let bootedImage: URL = {
        let image = Bundle.main.url(forResource: "SwiftyPharo", withExtension: "image")!
        PharoRuntime.shared.boot(image: image)
        return image
    }()
}
