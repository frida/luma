import Foundation
import Gtk
import LumaCore

@MainActor
final class LumaApplication {
    let app: Application
    private var mainWindow: MainWindow?
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
        let window = MainWindow(app: app)
        window.present()
        mainWindow = window

        Task { @MainActor in
            await self.boot()
        }
    }

    private func boot() async {
        let dataDirectory = Self.makeDataDirectory()
        let storePath = dataDirectory.appendingPathComponent("project.sqlite").path
        do {
            let store = try ProjectStore(path: storePath)
            let engine = Engine(store: store, dataDirectory: dataDirectory)
            self.engine = engine
            await engine.start()
            mainWindow?.attach(engine: engine)
        } catch {
            mainWindow?.showFatalError("Failed to start engine: \(error)")
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

// Tell Frida to use the host's existing GLib main loop instead of spawning
// its own background thread that fights us for g_main_context_default().
@_silgen_name("frida_init_with_runtime")
private func frida_init_with_runtime(_ runtime: Int32)

private let FRIDA_RUNTIME_GLIB: Int32 = 0

@main
struct LumaGtkMain {
    static func main() {
        frida_init_with_runtime(FRIDA_RUNTIME_GLIB)
        GLibMainExecutor.install()
        let app = LumaApplication()
        let status = app.run()
        if status != 0 {
            print("LumaGtk exited with status \(status)")
        }
    }
}
