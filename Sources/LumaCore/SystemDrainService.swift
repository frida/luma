import Frida

/// Shared out-of-process itrace drainer. One script attached to the device's
/// system session (PID 0) drains every target's ringbuffer, keyed by session
/// id. task_for_pid capability is fixed per device, so a single denial
/// disqualifies system draining for the whole device.
@MainActor
public final class SystemDrainService {
    private let device: Device
    private let agentSource: String
    private var session: Session?
    private var script: Script?
    private var capable: Bool?

    public init(device: Device, agentSource: String) {
        self.device = device
        self.agentSource = agentSource
    }

    func openBuffer(sessionId: String, location: String) async -> Bool {
        guard let script = await acquire() else { return false }
        do {
            try await script.exports.openBuffer(sessionId, location)
            return true
        } catch {
            capable = false
            return false
        }
    }

    func drain(sessionId: String) async throws -> [UInt8]? {
        try await script?.exports.drain(sessionId) as? [UInt8]
    }

    func lost(sessionId: String) async -> Int {
        (try? await script?.exports.getLost(sessionId)) as? Int ?? 0
    }

    func close(sessionId: String) async throws -> [UInt8]? {
        try await script?.exports.close(sessionId) as? [UInt8]
    }

    func shutdown() async {
        if let script {
            try? await script.unload()
            self.script = nil
        }
        if let session {
            try? await session.detach()
            self.session = nil
        }
    }

    private func acquire() async -> Script? {
        if let script { return script }
        guard capable != false else { return nil }

        do {
            let params = try await device.querySystemParameters()
            guard (params["platform"] as? String) == "darwin",
                (params["access"] as? String) == "full"
            else {
                capable = false
                return nil
            }

            let sysSession = try await device.attach(to: 0)
            let sysScript = try await sysSession.createScript(
                agentSource,
                name: "itrace-drain",
                runtime: .qjs
            )
            try await sysScript.load()

            session = sysSession
            script = sysScript
            return sysScript
        } catch {
            capable = false
            return nil
        }
    }
}
