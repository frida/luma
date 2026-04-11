import Combine
import Frida
import LumaCore
import SwiftUI
import SwiftyMonaco
import UniformTypeIdentifiers

#if os(macOS)

    @main
    struct LumaApp: App {
        @NSApplicationDelegateAdaptor(LumaAppDelegate.self) var appDelegate

        init() {
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaCodeShare()), count: 2)
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaTracerHook(packages: [])), count: 2)

        }

        var body: some Scene {
            DocumentGroup(newDocument: { LumaProject() }) { configuration in
                MainWindowView(store: configuration.document.store)
            }
            .defaultSize(width: 1100, height: 680)
        }
    }

    class LumaAppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSWindow.allowsAutomaticWindowTabbing = false
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            for url in urls {
                handle(url: url)
            }
        }

        private func handle(url: URL) {
            guard url.scheme == "luma", url.host == "join" else {
                return
            }

            guard let roomID = roomID(from: url) else {
                return
            }

            CollaborationJoinQueue.shared.enqueue(roomID: roomID)
        }

        private func roomID(from url: URL) -> String? {
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let roomItem = components.queryItems?.first(where: { $0.name == "room" }),
                let roomID = roomItem.value,
                !roomID.isEmpty
            else {
                return nil
            }

            return roomID
        }
    }

#else

    @main
    struct LumaApp: App {
        init() {
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaCodeShare()), count: 2)
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaTracerHook(packages: [])), count: 2)
        }

        var body: some Scene {
            DocumentGroup(newDocument: { LumaProject() }) { configuration in
                MainWindowView(store: configuration.document.store)
            }
        }
    }

#endif

