import Foundation
import Gtk
import LumaCore

@MainActor
final class LumaApplication {
    let app: Application

    init() {
        app = Application(applicationId: "re.frida.Luma")
    }

    func run(_ arguments: [String] = CommandLine.arguments) -> Int32 {
        app.onActivate { [weak self] _ in
            self?.activate()
        }
        let status = app.run(arguments)
        return status
    }

    private func activate() {
        let window = ApplicationWindow(application: app)
        window.title = "Luma"
        window.setDefaultSize(width: 1200, height: 800)
        window.show()
    }
}

@main
struct LumaGtkMain {
    static func main() {
        let app = LumaApplication()
        let status = app.run()
        if status != 0 {
            fatalError("Application exited with status \(status)")
        }
    }
}
