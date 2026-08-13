import Foundation
import SwiftyPharo

/// The image as the project sees it: started once, told about the host's
/// sessions, notebook and events, and holding on to whatever objects an
/// evaluation has produced so a later request can still reach them.
///
/// The image ships with LumaCore, the way the agent's JavaScript does, so a
/// frontend says nothing about where it lives. How a session without an icon
/// is drawn is its to answer; everything else is the same wherever Luma runs.
@MainActor
public final class PharoWorkspace {
    public var sessionIcon: ((ProcessSession) -> String?)?

    public let runtime = PharoRuntime.shared

    private weak var engine: Engine?
    private var hasBindings = false
    private var objects: [Int: PharoObject] = [:]

    public init(engine: Engine) {
        self.engine = engine
    }

    /// Every caller that needs the image asks for this; only the first one
    /// starts the VM and teaches it about the host, and the rest wait for it.
    @discardableResult
    public func started() async throws -> PharoRuntime {
        guard let engine else { throw PharoWorkspaceError.engineGone }

        Self.boot()
        try await runtime.runningState()

        let bridge = PharoHostBridge.shared
        bridge.publish(engine.sessions.map(recordWithIcon), as: .sessions)
        bridge.publish(engine.notebookEntries.map(\.recordForPharo), as: .notebookEntries)
        bridge.publish(engine.eventLog.events.suffix(200).map(\.recordForPharo), as: .events)

        guard !hasBindings else { return runtime }
        try await PharoLumaBindings.install(into: runtime)
        hasBindings = true
        return runtime
    }

    /// Starts the VM and returns at once, so a frontend that has to beat
    /// something else to the address space can ask for it before anything else
    /// runs. The build stages the image, so its absence is a broken build
    /// rather than a condition to handle.
    public nonisolated static func boot() {
        let image = Bundle.module.url(
            forResource: "SwiftyPharo", withExtension: "image", subdirectory: "pharo-image")!
        PharoRuntime.shared.boot(image: image)
    }

    /// A session that came with no icon still shows one, drawn the way the
    /// sidebar draws it.
    private func recordWithIcon(for session: ProcessSession) -> PharoHostRecord {
        var record = session.recordForPharo
        if record.icon == nil {
            record.icon = sessionIcon?(session)
        }
        return record
    }

    /// The image frees an object only when told to, so whoever hands one out
    /// keeps it here until its holder is done with it.
    @discardableResult
    public func remember(_ object: PharoObject) -> PharoObject {
        objects[object.handle] = object
        return object
    }

    public func object(handle: Int) throws -> PharoObject {
        guard let object = objects[handle] else { throw PharoWorkspaceError.unknownHandle(handle) }
        return object
    }

    public func release(handle: Int) async throws {
        let object = try object(handle: handle)
        objects[handle] = nil
        try await runtime.release(object)
    }

    public func releaseAll() async {
        let held = objects.values
        objects.removeAll()
        for object in held {
            try? await runtime.release(object)
        }
    }
}

public enum PharoWorkspaceError: Error, LocalizedError {
    case engineGone
    case unknownHandle(Int)

    public var errorDescription: String? {
        switch self {
        case .engineGone:
            "the project went away"
        case .unknownHandle(let handle):
            "no object \(handle) is being held; evaluate something first"
        }
    }
}
