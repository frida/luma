import Foundation
import Frida
import LumaCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("[vm-check] \(message)\n".utf8))
}

@MainActor
func run() async throws {
    let templateID = ProcessInfo.processInfo.environment["LUMA_VM_TEMPLATE"] ?? "qemu.linux"
    let architecture = ProcessInfo.processInfo.environment["LUMA_VM_ARCH"] ?? "arm64"

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("luma-vm-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ProjectStore(path: root.appendingPathComponent("db.sqlite").path)
    let deviceManager = DeviceManager()
    let manager = VirtualMachineManager(deviceManager: deviceManager, store: store, dataDirectory: root)
    manager.register(QemuBackend())

    guard let template = manager.templates.first(where: { $0.id == templateID }) else {
        fail("no template \(templateID)")
    }
    let availability = manager.availability(for: template)
    guard availability.isAvailable else { fail(availability.reason ?? "backend unavailable") }
    var parameters: [String: VirtualMachineParameterValue] = [
        VirtualMachineTemplate.architectureParameterID: .text(architecture)
    ]
    let variant = template.variant(for: parameters)
    guard let flavor = variant.agentFlavor else { fail("template has no agent flavor") }

    note("downloading Alpine starter images…")
    guard let starter = variant.starterImages else { fail("template has no starter images") }
    let starterPaths = try await manager.starterImages.download(starter)

    note("downloading barebone agent (\(flavor))…")
    _ = try await manager.agents.downloadLatest(flavor)

    for (key, url) in starterPaths {
        parameters[key] = .text(url.path)
    }

    note("booting \(template.name)…")
    let machine = try await manager.create(
        template: template,
        name: "vm-check",
        parameters: parameters,
        agentPath: nil
    )

    guard let device = manager.device(for: machine) else { fail("no barebone device for machine") }

    let started = Date()
    var lastAt = started
    let stageLog = Task { @MainActor in
        for await event in device.events {
            switch event {
            case .connecting(let status, let progress):
                let now = Date()
                note(String(format: "  %5.1f%%  +%.2fs  %@", progress * 100, now.timeIntervalSince(lastAt), status))
                lastAt = now
            case .connected:
                note(String(format: "  100.0%%  +%.2fs  connected (%.2fs total)",
                            Date().timeIntervalSince(lastAt), Date().timeIntervalSince(started)))
            default:
                break
            }
        }
    }

    note("attaching to the guest kernel (this drives the connecting stages)…")
    let session = try await device.attach(pid: 0)
    let script = try await session.createScript(source: "send(1 + 1);")
    let firstMessage = Task { () -> String? in
        for await event in script.events {
            if case .message(let message, _) = event { return "\(message)" }
        }
        return nil
    }
    try await script.load()

    let timeout = Task { () -> String? in
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        firstMessage.cancel()
        return nil
    }
    let message = await firstMessage.value
    timeout.cancel()
    note("MESSAGE \(message ?? "<none — timed out>")")

    try? await script.unload()
    stageLog.cancel()

    if let record = manager.records.first(where: { $0.id == machine.id }) {
        await manager.stop(record)
    }
    note("OK")
}

do {
    try await run()
} catch {
    fail("\(error)")
}
