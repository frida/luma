import Foundation
import LumaCore
import SwiftyPharo

extension PharoRuntime {
    /// Boots the image before GTK, WebKit and cairo reserve their large virtual
    /// regions, so the Spur heap still finds its expected base free. Returns at
    /// once; the image loads on its own thread.
    static func bootBundledImage() {
        PharoWorkspace.boot()
    }

    /// Waits for the already-booting image to answer and hands the project over
    /// to it. What that involves is the workspace's business; this only says how
    /// a session that came without an icon is drawn.
    @MainActor
    func startPlayground(for engine: Engine) async throws {
        engine.pharo.sessionIcon = { session in
            IconPlaceholderView.base64PNG(
                seed: "\(session.deviceID)/\(session.processName)",
                displayName: session.processName,
                pixelSize: 32)
        }
        try await engine.pharo.started()
    }
}
