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
            DocumentGroup(newDocument: LumaProject()) { configuration in
                MainWindowView(dbURL: configuration.document.temporaryDBURL)
            }
            .defaultSize(width: 1100, height: 680)
        }
    }

    class LumaAppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSWindow.allowsAutomaticWindowTabbing = false
            NSApplication.shared.registerForRemoteNotifications()
            LocalNotifier.requestAuthorization()
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            for url in urls {
                handle(url: url)
            }
        }

        func application(
            _ application: NSApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            Task { @MainActor in
                APNsRegistration.shared.setToken(deviceToken)
            }
        }

        func application(
            _ application: NSApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Swift.Error
        ) {
            Task { @MainActor in
                APNsRegistration.shared.setError(error.localizedDescription)
            }
        }

        private func handle(url: URL) {
            guard url.scheme == "luma", url.host == "join" else {
                return
            }

            guard let labID = labID(from: url) else {
                return
            }

            CollaborationJoinQueue.shared.enqueue(labID: labID)
        }

        private func labID(from url: URL) -> String? {
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let labItem = components.queryItems?.first(where: { $0.name == "lab" }),
                let labID = labItem.value,
                !labID.isEmpty
            else {
                return nil
            }

            return labID
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
            DocumentGroup(newDocument: LumaProject()) { configuration in
                MainWindowView(dbURL: configuration.document.temporaryDBURL)
            }
        }
    }

#endif

