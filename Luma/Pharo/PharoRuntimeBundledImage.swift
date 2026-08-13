import Foundation
import LumaCore
import SwiftyPharo

extension PharoRuntime {
    /// Every view that needs the runtime calls this. Starting the image is the
    /// workspace's business; the app only says how a session that came without
    /// an icon is drawn.
    @MainActor
    func startBundledImage(for engine: Engine) async throws {
        engine.pharo.sessionIcon = PharoSessionIcon.base64PNG(for:)
        try await engine.pharo.started()
    }
}
