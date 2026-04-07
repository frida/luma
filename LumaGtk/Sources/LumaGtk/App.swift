import Foundation
import Gtk
import LumaCore

@MainActor
final class LumaApplication {
    let app: Application
    private var engine: Engine?

    init() {
        guard let app = Application(id: "re.frida.Luma") else {
            fatalError("Unable to create Gtk application")
        }
        self.app = app
    }

    func run(_ arguments: [String] = CommandLine.arguments) -> Int {
        return app.run(arguments: arguments) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activate()
            }
        }
    }

    private func activate() {
        let window = ApplicationWindow(application: app)
        window.title = "Luma"
        window.setDefaultSize(width: 1200, height: 800)

        let box = Box(orientation: .vertical, spacing: 8)
        let header = Label(str: "Luma — GTK frontend")
        let status = Label(str: "Booting engine\u{2026}")
        box.append(child: header)
        box.append(child: status)
        window.set(child: box)

        window.present()

        Task { @MainActor in
            await self.boot(status: status)
        }
    }

    private func boot(status: Label) async {
        let dataDirectory = Self.makeDataDirectory()
        let storePath = dataDirectory.appendingPathComponent("project.sqlite").path
        do {
            let store = try ProjectStore(path: storePath)
            let engine = Engine(store: store, dataDirectory: dataDirectory)
            self.engine = engine
            await engine.start()

            let devices = await engine.deviceManager.currentDevices()
            let lines = devices.map { "\($0.name) [\($0.id)]" }
            let summary = lines.isEmpty ? "no devices" : lines.joined(separator: "\n")
            status.setText(str: "Devices:\n\(summary)")
            print("[LumaGtk] devices: \(lines)")
        } catch {
            status.setText(str: "Failed to start engine: \(error)")
            print("[LumaGtk] start failed: \(error)")
        }
    }

    private static func makeDataDirectory() -> URL {
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        let dir = xdg.appendingPathComponent("re.frida.Luma", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@main
struct LumaGtkMain {
    static func main() {
        let app = LumaApplication()
        let status = app.run()
        if status != 0 {
            print("LumaGtk exited with status \(status)")
        }
    }
}
