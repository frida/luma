import CoreGraphics
import Foundation
import Frida

final class GtkAppHarness: @unchecked Sendable {
    let user: TestUser
    private let binaryURL: URL
    private let gadgetPort: UInt16 = 27500

    private var process: Process?
    private var manager: DeviceManager?
    private var device: Device?
    private var session: Session?
    private var script: Script?

    init(user: TestUser, binaryURL: URL) {
        self.user = user
        self.binaryURL = binaryURL
    }

    func launchAndAttach(windowTimeout: TimeInterval = 10) async throws {
        try spawnProcess()
        try await attachViaGadget()
        try await waitForWindow(timeout: windowTimeout)
    }

    func windowSize() async throws -> CGSize {
        let script = try requireScript()
        let raw = try await script.exports.windowSize()
        guard let pair = raw as? [Any], pair.count == 2,
              let w = pair[0] as? Int, let h = pair[1] as? Int
        else { throw HarnessError.protocolMismatch("windowSize: \(raw)") }
        return CGSize(width: w, height: h)
    }

    func captureScreenshot(to url: URL) async throws {
        let script = try requireScript()
        let raw = try await script.exports.captureScreenshot()
        guard let bytes = raw as? [UInt8], bytes.count >= 8 else {
            throw HarnessError.protocolMismatch("captureScreenshot returned \(type(of: raw))")
        }
        let w = Int(UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24))
        let h = Int(UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24))
        let pixels = Array(bytes[8...])
        try writePNG(rgba: pixels, size: CGSize(width: w, height: h), to: url)
    }

    func sidebarLabels() async throws -> [String] {
        let script = try requireScript()
        let raw = try await script.exports.listSidebar()
        guard let items = raw as? [[String: Any]] else {
            throw HarnessError.protocolMismatch("listSidebar: \(raw)")
        }
        return items.compactMap { $0["label"] as? String }
    }

    func joinLab(labID: String) async throws {
        let script = try requireScript()
        _ = try await script.exports.joinLab(labID)
    }

    func debugWindowSummary() async throws -> [[String: Any]] {
        let script = try requireScript()
        let raw = try await script.exports.debugWindowSummary()
        return (raw as? [[String: Any]]) ?? []
    }

    func debugFirstNotebookEntry() async throws -> String {
        let script = try requireScript()
        let raw = try await script.exports.debugFirstNotebookEntry()
        return (raw as? String) ?? ""
    }

    func debugListBoxes() async throws -> [[String: Any]] {
        let script = try requireScript()
        let raw = try await script.exports.debugListBoxes()
        return (raw as? [[String: Any]]) ?? []
    }

    func notebookEntryTitles() async throws -> [String] {
        let script = try requireScript()
        let raw = try await script.exports.notebookEntryTitles()
        guard let items = raw as? [String] else {
            throw HarnessError.protocolMismatch("notebookEntryTitles: \(raw)")
        }
        return items
    }

    func expandEventStream() async throws {
        let script = try requireScript()
        _ = try await script.exports.expandEventStream()
    }

    func eventMessages() async throws -> [String] {
        let script = try requireScript()
        let raw = try await script.exports.eventMessages()
        return (raw as? [String]) ?? []
    }

    func eventCount() async throws -> Int {
        let script = try requireScript()
        let raw = try await script.exports.eventCount()
        return (raw as? NSNumber)?.intValue ?? 0
    }

    func selectReplRow() async throws {
        let script = try requireScript()
        _ = try await script.exports.selectReplRow()
    }

    func selectTracerRow() async throws {
        let script = try requireScript()
        _ = try await script.exports.selectTracerRow()
    }

    func monacoLatestText() async throws -> String? {
        let script = try requireScript()
        let raw = try await script.exports.monacoLatestText()
        return raw as? String
    }

    func sidebarSessionLabels() async throws -> [String] {
        let script = try requireScript()
        let raw = try await script.exports.sidebarSessionLabels()
        guard let items = raw as? [String] else {
            throw HarnessError.protocolMismatch("sidebarSessionLabels: \(raw)")
        }
        return items
    }

    func replCellCodes() async throws -> [String] {
        let script = try requireScript()
        let raw = try await script.exports.replCellCodes()
        guard let items = raw as? [String] else {
            throw HarnessError.protocolMismatch("replCellCodes: \(raw)")
        }
        return items
    }

    func shutdown() async {
        try? await script?.unload()
        script = nil
        try? await session?.detach()
        session = nil
        if let manager, let device {
            try? await manager.removeRemoteDevice(address: device.id)
        }
        device = nil
        manager = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
    }

    private func spawnProcess() throws {
        let bundle = Bundle(for: GtkAppHarness.self)
        guard let gadget = bundle.url(forResource: "frida-gadget", withExtension: "dylib") else {
            throw HarnessError.gadgetMissing
        }
        var env = user.launchEnvironment()
        env["DYLD_INSERT_LIBRARIES"] = gadget.path

        let p = Process()
        p.executableURL = binaryURL
        p.environment = env
        let devnull = FileHandle(forWritingAtPath: "/dev/null")!
        p.standardOutput = devnull
        let stderrPath = NSTemporaryDirectory() + "lumagtk-stderr.log"
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        p.standardError = FileHandle(forWritingAtPath: stderrPath)!
        print("[GtkAppHarness] LumaGtk stderr -> \(stderrPath)")
        try p.run()
        process = p
    }

    private func attachViaGadget() async throws {
        let manager = DeviceManager()
        self.manager = manager
        let address = "127.0.0.1:\(gadgetPort)"
        let device = try await manager.addRemoteDevice(address: address)
        self.device = device

        let target = try await waitForGadgetProcess(on: device)
        let session = try await device.attach(to: target.pid)
        let script = try await session.createScript(loadAgentSource(), name: "luma-gtk-control")
        try await script.load()
        self.session = session
        self.script = script
    }

    private func waitForGadgetProcess(on device: Device, timeout: TimeInterval = 10) async throws -> ProcessDetails {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Swift.Error?
        while Date() < deadline {
            do {
                let processes = try await device.enumerateProcesses(scope: .full)
                if let target = processes.first {
                    return target
                }
                lastError = HarnessError.protocolMismatch("gadget reported no process")
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw lastError ?? HarnessError.localDeviceUnavailable
    }

    private func loadAgentSource() throws -> String {
        let bundle = Bundle(for: GtkAppHarness.self)
        guard let url = bundle.url(forResource: "gtk-control-agent", withExtension: "js") else {
            throw HarnessError.agentResourceMissing
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func waitForWindow(timeout: TimeInterval) async throws {
        let script = try requireScript()
        _ = try await script.exports.waitForWindow(Int(timeout * 1000))
    }

    private func requireScript() throws -> Script {
        guard let script else { throw HarnessError.notLaunched }
        return script
    }
}

enum HarnessError: Swift.Error, CustomStringConvertible {
    case notLaunched
    case localDeviceUnavailable
    case agentResourceMissing
    case gadgetMissing
    case protocolMismatch(String)

    var description: String {
        switch self {
        case .notLaunched: return "harness not launched"
        case .localDeviceUnavailable: return "no local frida device"
        case .agentResourceMissing: return "gtk-control-agent.js missing from bundle resources"
        case .gadgetMissing: return "frida-gadget.dylib missing from bundle resources"
        case .protocolMismatch(let m): return "unexpected RPC reply: \(m)"
        }
    }
}
