import Foundation
import LumaCore
import SwiftyPharo

extension PharoRuntime {
    /// Every view that needs the runtime calls this; only the first one starts
    /// the VM and teaches it about the host, and the rest wait for it.
    @MainActor
    func startBundledImage(for engine: Engine) async throws {
        _ = Self.bootedImage
        try await runningState()

        let bridge = PharoHostBridge.shared
        bridge.publish(engine.sessions.map(\.recordForPharo), as: .sessions)
        bridge.publish(engine.notebookEntries.map(\.recordForPharo), as: .notebookEntries)
        bridge.publish(engine.eventLog.events.suffix(200).map(\.recordForPharo), as: .events)

        guard !Self.hasBindings else { return }
        try await PharoLumaBindings.install(into: self)
        Self.hasBindings = true
    }

    @MainActor
    private static var hasBindings = false

    /// The `Stage Pharo image` build phase puts this in the bundle, so its
    /// absence is a broken build rather than a condition to handle.
    private static let bootedImage: URL = {
        let image = Bundle.main.url(forResource: "SwiftyPharo", withExtension: "image")!
        PharoRuntime.shared.boot(image: image)
        return image
    }()
}
