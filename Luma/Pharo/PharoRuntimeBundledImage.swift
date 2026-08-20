import Foundation
import LumaCore
import SwiftyPharo

extension PharoRuntime {
    /// Boots the image before Monaco's web views reserve their large virtual
    /// regions, so the Spur heap still finds its expected base free. Returns at
    /// once; the image loads on its own thread.
    static func bootBundledImage() {
        PharoWorkspace.boot()
    }

    /// Every view that needs the runtime calls this. Starting the image is the
    /// workspace's business; the app only says how a session that came without
    /// an icon is drawn.
    @MainActor
    func startBundledImage(for engine: Engine) async throws {
        engine.pharo.sessionIcon = PharoSessionIcon.base64PNG(for:)
        try await engine.pharo.started()
    }
}
