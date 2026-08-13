import Adw
import CGLib
import CGtk
import CLuma
import Foundation
import Gdk
import Gtk
import LumaCore
import SwiftyPharo

@MainActor
final class LumaApplication {
    let app: Adw.Application

    private struct OpenDocument {
        let window: MainWindow
        let engine: Engine
        let workingURL: URL
        var document: LumaDocument
    }

    private var openDocuments: [ObjectIdentifier: OpenDocument] = [:]
    private(set) var primaryMenuPtr: UnsafeMutableRawPointer?
    private let maxRecentSlots = 10
    private var welcomeModel: WelcomeModel?
    private var activeWelcome: WelcomeWindow?

    init() {
        guard let app = Adw.Application(id: "re.frida.Luma", flags: .handlesOpen) else {
            fatalError("Unable to create Adw application")
        }
        self.app = app
    }

    func run(_ arguments: [String] = CommandLine.arguments) -> Int {
        let context = Unmanaged.passRetained(self).toOpaque()
        luma_app_set_open_handler(
            UnsafeMutableRawPointer(app.application_ptr),
            lumaOpenFilesThunk,
            context
        )
        return app.run(
            arguments: arguments,
            startupHandler: { [weak self] _ in
                MainActor.assumeIsolated { self?.startup() }
            },
            activationHandler: { [weak self] _ in
                MainActor.assumeIsolated { self?.activate() }
            }
        )
    }

    private func startup() {
        StyleSheet.install()
        registerDevelopmentIconPaths()
        installActions()
        purgeStaleWorkingCopies()
    }

    private func purgeStaleWorkingCopies() {
        let fm = FileManager.default
        let workingDir = LumaAppPaths.shared.workingDirectory
        guard let entries = try? fm.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    private func registerDevelopmentIconPaths() {
        let sourceTreeIcons = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("data/icons")
        guard FileManager.default.fileExists(
            atPath: sourceTreeIcons.appendingPathComponent("hicolor").path
        ) else { return }
        guard let display = Display.getDefault(),
              let theme = Gtk.IconThemeRef.getFor(display: display) else { return }
        theme.addSearch(path: sourceTreeIcons.path)
    }

    private func activate() {
        PangoGlyphAtlas.install()
        ensureDocumentWindow()
    }

    fileprivate func ensureDocumentWindow() {
        if !openDocuments.isEmpty {
            return
        }

        let cliPaths = parseDocumentPaths(from: CommandLine.arguments)
        if !cliPaths.isEmpty {
            for path in cliPaths {
                openWindow(forFile: URL(fileURLWithPath: path))
            }
            return
        }

        if restorePreviousSession() {
            return
        }

        showWelcome()
    }

    private func restorePreviousSession() -> Bool {
        let fm = FileManager.default
        let remembered = LumaAppState.shared.openDocumentPaths
        let surviving = remembered.filter { fm.fileExists(atPath: $0) }
        if surviving != remembered {
            LumaAppState.shared.setOpenDocumentPaths(surviving)
        }
        for path in surviving {
            openWindow(forFile: URL(fileURLWithPath: path))
        }
        return !surviving.isEmpty
    }

    func showWelcome() {
        if let active = activeWelcome {
            active.window.present()
            return
        }
        let window = WelcomeWindow(app: app, application: self, welcome: ensuredWelcomeModel())
        activeWelcome = window
        window.present()
    }

    func welcomeWindowDidClose() {
        activeWelcome = nil
    }

    private func ensuredWelcomeModel() -> WelcomeModel {
        if let welcomeModel { return welcomeModel }
        let model = WelcomeModel(dataDirectory: LumaAppPaths.shared.dataDirectory)
        welcomeModel = model
        return model
    }

    func openNewUntitledWindow() {
        do {
            let document = try LumaDocumentLoader.makeUntitled(in: LumaAppPaths.shared.untitledDirectory)
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
            let workingURL = try prepareWorkingCopy(of: document)
            let engine = try buildEngine(workingURL: workingURL)
            openDocuments[key] = OpenDocument(
                window: window,
                engine: engine,
                workingURL: workingURL,
                document: document
            )
            window.present()

            Task { @MainActor in
                await engine.start()
                window.attach(engine: engine)
            }

            recordDocumentOpened(document)
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
            LumaAppState.shared.lastDocumentPath = document.url.path
            LumaAppState.shared.recordRecent(path: document.url.path)
            rebuildPrimaryMenu()
        }
    }

    func beginWindowClose(_ window: MainWindow, persist: Bool) {
        let key = ObjectIdentifier(window)
        guard let entry = openDocuments.removeValue(forKey: key) else {
            window.destroyWindow()
            return
        }
        if !entry.document.isUntitled {
            LumaAppState.shared.noteDocumentClosed(path: entry.document.url.path)
        }
        app.hold()
        Task { @MainActor in
            await persistAndShutDown(entry, persist: persist)
            window.destroyWindow()
            app.release()
            if openDocuments.isEmpty && activeWelcome == nil {
                showWelcome()
            }
        }
    }

    func save(window: MainWindow) {
        let key = ObjectIdentifier(window)
        guard let entry = openDocuments[key] else { return }
        if entry.document.isUntitled {
            presentSaveAsDialog(for: window, closeAfterSave: false)
            return
        }
        do {
            try Self.writeSnapshot(workingURL: entry.workingURL, to: entry.document.url)
            window.documentDidSave()
        } catch {
            FileHandle.standardError.write(
                "Save failed: \(error)\n".data(using: .utf8)!
            )
        }
    }

    func saveAs(window: MainWindow, destination: URL) {
        let key = ObjectIdentifier(window)
        guard var entry = openDocuments[key] else { return }
        do {
            try Self.writeSnapshot(workingURL: entry.workingURL, to: destination)
            let previous = entry.document
            let updated = LumaDocument(storage: .file(destination))
            entry.document = updated
            openDocuments[key] = entry
            if !previous.isUntitled {
                LumaAppState.shared.noteDocumentClosed(path: previous.url.path)
            }
            LumaAppState.shared.lastDocumentPath = updated.url.path
            LumaAppState.shared.recordRecent(path: updated.url.path)
            LumaAppState.shared.noteDocumentOpened(path: updated.url.path)
            rebuildPrimaryMenu()
            window.documentDidChange()
        } catch {
            FileHandle.standardError.write(
                "Save As failed: \(error)\n".data(using: .utf8)!
            )
        }
    }

    private func prepareWorkingCopy(of document: LumaDocument) throws -> URL {
        let fm = FileManager.default
        let workingDir = LumaAppPaths.shared.workingDirectory
        try fm.createDirectory(at: workingDir, withIntermediateDirectories: true)
        let workingURL = workingDir.appendingPathComponent(
            "Working-\(UUID().uuidString).luma",
            isDirectory: true
        )

        if fm.fileExists(atPath: document.sqliteURL.path) {
            try fm.copyItem(at: document.url, to: workingURL)
        } else {
            try fm.createDirectory(at: workingURL, withIntermediateDirectories: true)
        }
        try fm.createDirectory(
            at: workingURL.appendingPathComponent("traces", isDirectory: true),
            withIntermediateDirectories: true
        )
        return workingURL
    }

    private func buildEngine(workingURL: URL) throws -> Engine {
        let store = try ProjectStore(path: workingURL.appendingPathComponent("db.sqlite").path)
        let blobs = try BlobStore(
            directory: workingURL.appendingPathComponent("traces", isDirectory: true)
        )
        let eventStore = EventStore(fileURL: workingURL.appendingPathComponent("events.log"))
        let engine = Engine(
            store: store,
            blobs: blobs,
            eventStore: eventStore,
            dataDirectory: LumaAppPaths.shared.dataDirectory,
            gitHubAuth: ensuredWelcomeModel().gitHubAuth
        )
        engine.imageProcessor = HostImageProcessor()
        return engine
    }

    private func recordDocumentOpened(_ document: LumaDocument) {
        LumaAppState.shared.lastDocumentPath = document.url.path
        if !document.isUntitled {
            LumaAppState.shared.recordRecent(path: document.url.path)
            LumaAppState.shared.noteDocumentOpened(path: document.url.path)
            rebuildPrimaryMenu()
        }
    }

    private func persistAndShutDown(_ entry: OpenDocument, persist: Bool) async {
        await entry.engine.shutdown()
        let workingURL = entry.workingURL
        let destination = entry.document.url
        await Task.detached(priority: .userInitiated) {
            if persist {
                try? Self.writeSnapshot(workingURL: workingURL, to: destination)
            }
            try? FileManager.default.removeItem(at: workingURL)
        }.value
    }

    private nonisolated static func writeSnapshot(workingURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent
            .appendingPathComponent(".luma-save-\(UUID().uuidString).luma", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try ProjectSnapshot.snapshot(from: workingURL, to: staging)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
    }

    fileprivate func handleOpenPath(_ path: String) {
        openWindow(forFile: URL(fileURLWithPath: path))
    }

    fileprivate func handleCollaborationURL(_ urlString: String) {
        guard let url = URL(string: urlString), let labID = labID(fromURL: url) else { return }
        if let existing = openDocuments.values.first {
            existing.engine.startCollaboration(joiningLab: labID)
            return
        }
        CollaborationJoinQueue.shared.enqueue(labID: labID)
        openNewUntitledWindow()
    }

    private func labID(fromURL url: URL) -> String? {
        if let labID = BackendConfig.labID(fromInviteLink: url) {
            return labID
        }
        guard url.scheme == "luma", url.host == "join",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let labID = components.queryItems?.first(where: { $0.name == "lab" })?.value,
            !labID.isEmpty
        else { return nil }
        return labID
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
            luma_folder_dialog_select(parentPtr, title, lumaOpenPathThunk, context)
        }
    }

    func presentWelcomeOpenDialog(parent: WelcomeWindow) {
        guard let parentPtr = parent.window.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let context = Unmanaged.passRetained(WelcomeOpenContext(welcome: parent)).toOpaque()
        "Open Project".withCString { title in
            luma_folder_dialog_select(parentPtr, title, lumaWelcomeOpenPathThunk, context)
        }
    }

    fileprivate func presentSaveAsDialog() {
        guard let active = activeWindow() else { return }
        presentSaveAsDialog(for: active, closeAfterSave: false)
    }

    func presentSaveAsForClose(window: MainWindow) {
        presentSaveAsDialog(for: window, closeAfterSave: true)
    }

    private func presentSaveAsDialog(for window: MainWindow, closeAfterSave: Bool) {
        guard let parentPtr = window.window.window_ptr.map(UnsafeMutableRawPointer.init) else { return }
        let suggested = "\(window.document.displayName).\(LumaDocumentLoader.fileExtension)"
        let context = Unmanaged.passRetained(
            SaveAsContext(app: self, window: window, closeAfterSave: closeAfterSave)
        ).toOpaque()
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
        installAction(appPtr: appPtr, name: "save") { [weak self] in
            guard let self, let active = self.activeWindow() else { return }
            self.save(window: active)
        }
        installAction(appPtr: appPtr, name: "save-as") { [weak self] in
            self?.presentSaveAsDialog()
        }
        installAction(appPtr: appPtr, name: "close-window") { [weak self] in
            self?.activeWindow()?.window.close()
        }
        installAction(appPtr: appPtr, name: "new-session") { [weak self] in
            self?.activeWindow()?.newSession()
        }
        installAction(appPtr: appPtr, name: "add-instrument") { [weak self] in
            self?.activeWindow()?.addInstrument()
        }
        installAction(appPtr: appPtr, name: "resume-process") { [weak self] in
            self?.activeWindow()?.resumeProcess()
        }
        installAction(appPtr: appPtr, name: "manage-packages") { [weak self] in
            self?.activeWindow()?.managePackages()
        }
        installAction(appPtr: appPtr, name: "toggle-collaboration") { [weak self] in
            self?.activeWindow()?.toggleCollaboration()
        }
        installAction(appPtr: appPtr, name: "about") { [weak self] in
            self?.presentAboutDialog()
        }
        installAction(appPtr: appPtr, name: "show-help-overlay") { [weak self] in
            self?.presentShortcutsDialog()
        }
        for slot in 0..<maxRecentSlots {
            installAction(appPtr: appPtr, name: "open-recent-\(slot)") { [weak self] in
                self?.openRecent(slot: slot)
            }
        }

        for group in Self.shortcutGroups {
            for item in group.items {
                setAccel(appPtr: appPtr, action: item.action, accel: item.accel)
            }
        }

        primaryMenuPtr = luma_menu_new()
        rebuildPrimaryMenu()
    }

    private func openRecent(slot: Int) {
        let recents = LumaAppState.shared.recentPaths
        guard slot < recents.count else { return }
        openWindow(forFile: URL(fileURLWithPath: recents[slot]))
    }

    private var lastBuiltRecentsSignature: String = ""
    private var primaryMenuBuilt: Bool = false
    private var recentMenuPtr: UnsafeMutableRawPointer?

    func rebuildPrimaryMenu() {
        guard let menu = primaryMenuPtr else { return }
        let signature = LumaAppState.shared.recentPaths.joined(separator: "\u{1f}")
        if primaryMenuBuilt && signature == lastBuiltRecentsSignature {
            return
        }
        lastBuiltRecentsSignature = signature

        if !primaryMenuBuilt {
            buildPrimaryMenuStructure(menu: menu)
            primaryMenuBuilt = true
        }

        rebuildRecentMenu()
    }

    private func buildPrimaryMenuStructure(menu: UnsafeMutableRawPointer) {
        let topSection = luma_menu_new()!
        appendItem(toMenu: topSection, label: "New Window", action: "app.new-window")
        appendItem(toMenu: topSection, label: "Open\u{2026}", action: "app.open")

        let recentMenu = luma_menu_new()!
        "Open Recent".withCString { label in
            luma_menu_append_submenu(topSection, label, recentMenu)
        }
        recentMenuPtr = recentMenu

        luma_menu_append_section(menu, topSection)
        luma_menu_unref(topSection)

        let docSection = luma_menu_new()!
        appendItem(toMenu: docSection, label: "Save", action: "app.save")
        appendItem(toMenu: docSection, label: "Save As\u{2026}", action: "app.save-as")
        luma_menu_append_section(menu, docSection)
        luma_menu_unref(docSection)

        let helpSection = luma_menu_new()!
        appendItem(toMenu: helpSection, label: "Keyboard Shortcuts", action: "app.show-help-overlay")
        appendItem(toMenu: helpSection, label: "About Luma", action: "app.about")
        luma_menu_append_section(menu, helpSection)
        luma_menu_unref(helpSection)
    }

    private func rebuildRecentMenu() {
        guard let recentMenu = recentMenuPtr else { return }
        luma_menu_remove_all(recentMenu)
        let recents = LumaAppState.shared.recentPaths.prefix(maxRecentSlots)
        for (i, path) in recents.enumerated() {
            let label = (path as NSString).lastPathComponent
            appendItem(toMenu: recentMenu, label: label, action: "app.open-recent-\(i)")
        }
    }

    private func presentShortcutsDialog() {
        #if HAS_ADW_SHORTCUTS_DIALOG
        let dialog = Adw.ShortcutsDialog()
        for group in Self.shortcutGroups {
            let section = Adw.ShortcutsSection(title: group.title)
            for item in group.items {
                section.add(item: Adw.ShortcutsItem(action: item.title, actionName: item.action))
            }
            dialog.add(section: section)
        }
        let parent = activeWindow()?.window
        dialog.present(parent: parent)
        #else
        presentLegacyShortcutsDialog()
        #endif
    }

    #if !HAS_ADW_SHORTCUTS_DIALOG
    private func presentLegacyShortcutsDialog() {
        let dialog = Adw.Dialog()
        dialog.set(title: "Keyboard Shortcuts")
        dialog.set(contentWidth: 480)
        dialog.set(contentHeight: 560)

        let content = Box(orientation: .vertical, spacing: 16)
        content.marginStart = 24
        content.marginEnd = 24
        content.marginTop = 12
        content.marginBottom = 24

        for group in Self.shortcutGroups {
            let title = Label(str: group.title)
            title.add(cssClass: "heading")
            title.halign = .start
            content.append(child: title)

            let list = ListBox()
            list.selectionMode = .none
            list.add(cssClass: "boxed-list")
            for item in group.items {
                let row = Adw.ActionRow()
                row.set(title: item.title)
                let label = Label(str: Self.humanReadableAccel(item.accel))
                label.add(cssClass: "dim-label")
                row.addSuffix(widget: label)
                list.append(child: row)
            }
            content.append(child: list)
        }

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: content)

        let header = Adw.HeaderBar()
        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: scroll)
        dialog.set(child: toolbarView)

        let parent = activeWindow()?.window
        dialog.present(parent: parent)
    }

    private static func humanReadableAccel(_ accel: String) -> String {
        var keyval: guint = 0
        var rawMods = GdkModifierType(rawValue: 0)
        _ = Gtk.acceleratorParse(accelerator: accel, acceleratorKey: &keyval, acceleratorMods: &rawMods)
        let mods = Gdk.ModifierType(rawValue: UInt32(rawMods.rawValue))
        return Gtk.acceleratorGetLabel(acceleratorKey: Int(keyval), acceleratorMods: mods)
    }
    #endif

    private struct ShortcutEntry {
        let title: String
        let action: String
        let accel: String
    }

    private struct ShortcutGroup {
        let title: String
        let items: [ShortcutEntry]
    }

    private static let shortcutGroups: [ShortcutGroup] = [
        ShortcutGroup(title: "General", items: [
            ShortcutEntry(title: "New Window", action: "app.new-window", accel: "<Primary>n"),
            ShortcutEntry(title: "Open Project\u{2026}", action: "app.open", accel: "<Primary>o"),
            ShortcutEntry(title: "Save", action: "app.save", accel: "<Primary>s"),
            ShortcutEntry(title: "Save As\u{2026}", action: "app.save-as", accel: "<Primary><Shift>s"),
            ShortcutEntry(title: "Close Window", action: "app.close-window", accel: "<Primary>w"),
            ShortcutEntry(title: "Keyboard Shortcuts", action: "app.show-help-overlay", accel: "<Primary>question"),
        ]),
        ShortcutGroup(title: "Sessions", items: [
            ShortcutEntry(title: "New Session\u{2026}", action: "app.new-session", accel: "<Primary><Alt>n"),
            ShortcutEntry(title: "Add Instrument\u{2026}", action: "app.add-instrument", accel: "<Primary><Shift>i"),
            ShortcutEntry(title: "Resume Process", action: "app.resume-process", accel: "<Primary>r"),
        ]),
        ShortcutGroup(title: "Packages", items: [
            ShortcutEntry(title: "Install Package\u{2026}", action: "app.manage-packages", accel: "<Primary><Alt>p"),
        ]),
        ShortcutGroup(title: "Collaboration", items: [
            ShortcutEntry(title: "Toggle Collaboration Panel", action: "app.toggle-collaboration", accel: "<Primary><Alt>c"),
        ]),
    ]

    private func presentAboutDialog() {
        let dialog = Adw.AboutDialog()
        dialog.set(applicationName: "Luma")
        dialog.set(applicationIcon: "re.frida.Luma")
        dialog.set(version: LumaVersion.string)
        dialog.set(developerName: "Ole André Vadla Ravnås")
        dialog.set(copyright: "© 2025–2026 Ole André Vadla Ravnås")
        dialog.set(website: "https://luma.frida.re")
        dialog.set(issueUrl: "https://github.com/frida/luma/issues")
        dialog.set(licenseType: .mitX11)

        let entries = ["NowSecure https://www.nowsecure.com"]
        let cStrings = entries.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        ptrs.append(nil)
        ptrs.withUnsafeMutableBufferPointer { buf in
            dialog.addAcknowledgementSection(name: "Sponsored by", people: buf.baseAddress)
        }

        let parent = activeWindow()?.window
        dialog.present(parent: parent)
    }

    private func appendItem(
        toMenu menu: UnsafeMutableRawPointer,
        label: String,
        action: String
    ) {
        luma_menu_append(menu, label, action)
    }

    private func installAction(
        appPtr: UnsafeMutableRawPointer,
        name: String,
        handler: @escaping () -> Void
    ) {
        let box = ActionHandlerBox(handler: handler)
        let context = Unmanaged.passRetained(box).toOpaque()
        luma_action_install(appPtr, name, lumaActionThunk, context)
    }

    private func setAccel(
        appPtr: UnsafeMutableRawPointer,
        action: String,
        accel: String
    ) {
        luma_app_set_accels(appPtr, action, accel)
    }

    private func parseDocumentPaths(from arguments: [String]) -> [String] {
        arguments.dropFirst().filter { arg in
            !arg.hasPrefix("-") && arg.hasSuffix(".\(LumaDocumentLoader.fileExtension)")
        }
    }

}

private final class ActionHandlerBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}

private final class SaveAsContext {
    let app: LumaApplication
    let window: MainWindow
    let closeAfterSave: Bool
    init(app: LumaApplication, window: MainWindow, closeAfterSave: Bool) {
        self.app = app
        self.window = window
        self.closeAfterSave = closeAfterSave
    }
}

@MainActor
private final class WelcomeOpenContext {
    weak var welcome: WelcomeWindow?
    init(welcome: WelcomeWindow) { self.welcome = welcome }
}

private let lumaWelcomeOpenPathThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    let pathString: String? = pathPtr.map { String(cString: $0) }
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let ctx = Unmanaged<WelcomeOpenContext>.fromOpaque(ptr).takeRetainedValue()
        if let pathString {
            ctx.welcome?.handleOpenedFromWelcome(path: pathString)
        }
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
            if ctx.closeAfterSave {
                ctx.window.proceedWithClose(persist: false)
            }
        }
    }
}

private let lumaOpenFilesThunk: @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { pathPtr, userData in
    guard let pathPtr, let userData else { return }
    let str = String(cString: pathPtr)
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let app = Unmanaged<LumaApplication>.fromOpaque(ptr).takeUnretainedValue()
        if str.hasPrefix("luma://") || str.hasPrefix(BackendConfig.inviteLinkBase) {
            app.handleCollaborationURL(str)
        } else {
            app.openWindow(forFile: URL(fileURLWithPath: str))
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
        PharoRuntime.bootBundledImage()
        "luma".withCString { g_set_prgname($0) }
        frida_init_with_runtime(FRIDA_RUNTIME_GLIB)
        GLibMainExecutor.install()
        let app = LumaApplication()
        let status = app.run()
        if status != 0 {
            print("LumaGtk exited with status \(status)")
        }
    }
}
