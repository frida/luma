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

    /// Waits for the already-booting image to answer, feeds it the project's
    /// sessions, notebook entries and events, and teaches it the Luma bindings
    /// once so `LumaProject sessions` and friends resolve.
    @MainActor
    func startPlayground(for engine: Engine) async throws {
        Self.bootBundledImage()
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

    /// The Makefile stages this into the resource bundle before building, so its
    /// absence is a broken build rather than a condition to handle.
    private static let bootedImage: URL = {
        let image = Bundle.module.url(forResource: "SwiftyPharo", withExtension: "image", subdirectory: "pharo-image")!
        PharoRuntime.shared.boot(image: image)
        return image
    }()
}
