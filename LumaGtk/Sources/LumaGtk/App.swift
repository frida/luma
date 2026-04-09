import CGLib
import CWebKit
import Foundation
import Gtk
import LumaCore

@MainActor
final class LumaApplication {
    let app: Application

    private struct OpenDocument {
        let window: MainWindow
        let engine: Engine
        var document: LumaDocument
    }

    private var openDocuments: [ObjectIdentifier: OpenDocument] = [:]
    private(set) var primaryMenuPtr: UnsafeMutableRawPointer?
    private let maxRecentSlots = 10

    init() {
        guard let app = Application(id: "re.frida.Luma") else {
            fatalError("Unable to create Gtk application")
        }
        self.app = app
    }

    func run(_ arguments: [String] = CommandLine.arguments) -> Int {
        let filtered = arguments.filter { $0 != "--monaco-demo" }
        return app.run(arguments: filtered) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activate()
            }
        }
    }

    private func activate() {
        StyleSheet.install()
        if CommandLine.arguments.contains("--monaco-demo") {
            MonacoDemo.present(in: app)
            return
        }

        installActions()

        let cliPaths = parseDocumentPaths(from: CommandLine.arguments)
        if !cliPaths.isEmpty {
            for path in cliPaths {
                openWindow(forFile: URL(fileURLWithPath: path))
            }
            return
        }

        let lastPath = LumaState.shared.lastDocumentPath
        if let lastPath, FileManager.default.fileExists(atPath: lastPath) {
            openWindow(forFile: URL(fileURLWithPath: lastPath))
            return
        }

        openNewUntitledWindow()
    }

    func openNewUntitledWindow() {
        do {
            let document = try LumaDocumentLoader.makeUntitled(in: Self.untitledDirectory)
            openWindow(for: document)
        } catch {
            FileHandle.standardError.write(
                "Failed to create untitled document: \(error)\n".data(using: .utf8)!
            )
        }
    }

    func openWindow(forFile url: URL) {
        do {
            let document = try LumaDocumentLoader.open(at: url)
            openWindow(for: document)
        } catch {
            FileHandle.standardError.write(
                "Failed to open \(url.path): \(error)\n".data(using: .utf8)!
            )
        }
    }

    func openWindow(for document: LumaDocument) {
        let window = MainWindow(app: app, application: self, document: document)
        let key = ObjectIdentifier(window)

        do {
            let store = try ProjectStore(path: document.sqlitePath)
            let engine = Engine(store: store, dataDirectory: Self.dataDirectory)
            openDocuments[key] = OpenDocument(window: window, engine: engine, document: document)
            window.present()

            Task { @MainActor in
                await engine.start()
                window.attach(engine: engine)
            }

            if !document.isUntitled {
                LumaState.shared.lastDocumentPath = document.url.path
                LumaState.shared.recordRecent(path: document.url.path)
                rebuildPrimaryMenu()
            }
        } catch {
            window.present()
            window.showFatalError("Failed to open project: \(error)")
            openDocuments[key] = nil
        }
    }

    func documentForWindow(_ window: MainWindow) -> LumaDocument? {
        openDocuments[ObjectIdentifier(window)]?.document
    }

    func updateDocumentForWindow(_ window: MainWindow, to document: LumaDocument) {
        let key = ObjectIdentifier(window)
        guard var entry = openDocuments[key] else { return }
        entry.document = document
        openDocuments[key] = entry
        if !document.isUntitled {
            LumaState.shared.lastDocumentPath = document.url.path
            LumaState.shared.recordRecent(path: document.url.path)
            rebuildPrimaryMenu()
        }
    }

    func windowDidClose(_ window: MainWindow) {
        openDocuments[ObjectIdentifier(window)] = nil
    }

    func saveAs(window: MainWindow, destination: URL) {
        let key = ObjectIdentifier(window)
        guard let entry = openDocuments[key] else { return }
        do {
            let updated = try LumaDocumentLoader.saveAs(entry.document, to: destination)
            updateDocumentForWindow(window, to: updated)
            window.documentDidChange()
        } catch {
            FileHandle.standardError.write(
                "Save As failed: \(error)\n".data(using: .utf8)!
            )
        }
    }

    fileprivate func handleOpenPath(_ path: String) {
        openWindow(forFile: URL(fileURLWithPath: path))
    }

    fileprivate func handleSaveAsPath(window: MainWindow, _ path: String) {
        var destination = URL(fileURLWithPath: path)
        if destination.pathExtension != LumaDocumentLoader.fileExtension {
            destination = destination.appendingPathExtension(LumaDocumentLoader.fileExtension)
        }
        saveAs(window: window, destination: destination)
    }

    fileprivate func presentOpenDialog() {
        guard let active = activeWindow() else { return }
        guard let parentPtr = active.window.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        "Open Project".withCString { title in
            luma_file_dialog_open(parentPtr, title, lumaOpenPathThunk, context)
        }
    }

    fileprivate func presentSaveAsDialog() {
        guard let active = activeWindow() else { return }
        guard let parentPtr = active.window.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let suggested = "\(active.document.displayName).\(LumaDocumentLoader.fileExtension)"
        let context = Unmanaged.passRetained(SaveAsContext(app: self, window: active)).toOpaque()
        "Save Project As".withCString { title in
            suggested.withCString { name in
                luma_file_dialog_save(parentPtr, title, name, lumaSavePathThunk, context)
            }
        }
    }

    fileprivate func activeWindow() -> MainWindow? {
        openDocuments.values.first?.window
    }

    private func installActions() {
        guard let appPtr = app.application_ptr.map(UnsafeMutableRawPointer.init) else { return }
        installAction(appPtr: appPtr, name: "new-window") { [weak self] in
            self?.openNewUntitledWindow()
        }
        installAction(appPtr: appPtr, name: "open") { [weak self] in
            self?.presentOpenDialog()
        }
        installAction(appPtr: appPtr, name: "save-as") { [weak self] in
            self?.presentSaveAsDialog()
        }
        installAction(appPtr: appPtr, name: "close-window") { [weak self] in
            self?.activeWindow()?.window.close()
        }
        for slot in 0..<maxRecentSlots {
            installAction(appPtr: appPtr, name: "open-recent-\(slot)") { [weak self] in
                self?.openRecent(slot: slot)
            }
        }

        setAccel(appPtr: appPtr, action: "app.new-window", accel: "<Primary>n")
        setAccel(appPtr: appPtr, action: "app.open", accel: "<Primary>o")
        setAccel(appPtr: appPtr, action: "app.save-as", accel: "<Primary><Shift>s")
        setAccel(appPtr: appPtr, action: "app.close-window", accel: "<Primary>w")

        primaryMenuPtr = luma_menu_new()
        rebuildPrimaryMenu()
    }

    private func openRecent(slot: Int) {
        let recents = LumaState.shared.recentPaths
        guard slot < recents.count else { return }
        openWindow(forFile: URL(fileURLWithPath: recents[slot]))
    }

    private var lastBuiltRecentsSignature: String = ""
    private var primaryMenuBuilt: Bool = false

    func rebuildPrimaryMenu() {
        guard let menu = primaryMenuPtr else { return }
        let signature = LumaState.shared.recentPaths.joined(separator: "\u{1f}")
        if primaryMenuBuilt && signature == lastBuiltRecentsSignature {
            return
        }
        lastBuiltRecentsSignature = signature
        primaryMenuBuilt = true
        luma_menu_remove_all(menu)

        let topSection = luma_menu_new()
        appendItem(toMenu: topSection!, label: "New Window", action: "app.new-window")
        appendItem(toMenu: topSection!, label: "Open\u{2026}", action: "app.open")

        let recents = LumaState.shared.recentPaths.prefix(maxRecentSlots)
        if !recents.isEmpty {
            let recentMenu = luma_menu_new()!
            for (i, path) in recents.enumerated() {
                let label = (path as NSString).lastPathComponent
                appendItem(toMenu: recentMenu, label: label, action: "app.open-recent-\(i)")
            }
            "Open Recent".withCString { label in
                luma_menu_append_submenu(topSection, label, recentMenu)
            }
            luma_menu_unref(recentMenu)
        }

        luma_menu_append_section(menu, topSection)
        luma_menu_unref(topSection)

        let docSection = luma_menu_new()!
        appendItem(toMenu: docSection, label: "Save As\u{2026}", action: "app.save-as")
        luma_menu_append_section(menu, docSection)
        luma_menu_unref(docSection)

        let windowSection = luma_menu_new()!
        appendItem(toMenu: windowSection, label: "Close Window", action: "app.close-window")
        luma_menu_append_section(menu, windowSection)
        luma_menu_unref(windowSection)
    }

    private func appendItem(
        toMenu menu: UnsafeMutableRawPointer,
        label: String,
        action: String
    ) {
        label.withCString { l in
            action.withCString { a in
                luma_menu_append(menu, l, a)
            }
        }
    }

    private func installAction(
        appPtr: UnsafeMutableRawPointer,
        name: String,
        handler: @escaping () -> Void
    ) {
        let box = ActionHandlerBox(handler: handler)
        let context = Unmanaged.passRetained(box).toOpaque()
        name.withCString { cstr in
            luma_action_install(appPtr, cstr, lumaActionThunk, context)
        }
    }

    private func setAccel(
        appPtr: UnsafeMutableRawPointer,
        action: String,
        accel: String
    ) {
        action.withCString { actionCstr in
            accel.withCString { accelCstr in
                luma_app_set_accels(appPtr, actionCstr, accelCstr)
            }
        }
    }

    private func parseDocumentPaths(from arguments: [String]) -> [String] {
        arguments.dropFirst().filter { arg in
            !arg.hasPrefix("-") && arg.hasSuffix(".\(LumaDocumentLoader.fileExtension)")
        }
    }

    static var dataDirectory: URL {
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        let dir = xdg.appendingPathComponent("luma", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var untitledDirectory: URL {
        let dir = dataDirectory.appendingPathComponent("Untitled", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private final class ActionHandlerBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}

private final class SaveAsContext {
    let app: LumaApplication
    let window: MainWindow
    init(app: LumaApplication, window: MainWindow) {
        self.app = app
        self.window = window
    }
}

private let lumaActionThunk: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let box = Unmanaged<ActionHandlerBox>.fromOpaque(ptr).takeUnretainedValue()
        box.handler()
    }
}

private let lumaOpenPathThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let pathString: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let appRef = Unmanaged<LumaApplication>.fromOpaque(ptr).takeRetainedValue()
        if let pathString {
            appRef.handleOpenPath(pathString)
        }
    }
}

private let lumaSavePathThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let pathString: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let ctx = Unmanaged<SaveAsContext>.fromOpaque(ptr).takeRetainedValue()
        if let pathString {
            ctx.app.handleSaveAsPath(window: ctx.window, pathString)
        }
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
        "luma".withCString { g_set_prgname($0) }
        let isMonacoDemo = CommandLine.arguments.contains("--monaco-demo")
        if !isMonacoDemo {
            frida_init_with_runtime(FRIDA_RUNTIME_GLIB)
        }
        GLibMainExecutor.install()
        let app = LumaApplication()
        let status = app.run()
        if status != 0 {
            print("LumaGtk exited with status \(status)")
        }
    }
}
