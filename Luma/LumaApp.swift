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
        @StateObject private var updater = LumaUpdater()

        init() {
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaCodeShare()), count: 2)
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaTracerHook(packages: [])), count: 2)

        }

        var body: some Scene {
            DocumentGroup(newDocument: LumaProject()) { configuration in
                MainWindowView(
                    dbURL: configuration.document.workingDBURL,
                    fileURL: configuration.fileURL,
                    project: configuration.$document
                )
            }
            .defaultSize(width: 1100, height: 680)
            .commands {
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesView(updater: updater)
                }
            }
        }
    }

    class LumaAppDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
            false
        }

        func application(_ application: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
            false
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSWindow.allowsAutomaticWindowTabbing = false
            NSApplication.shared.registerForRemoteNotifications()
            LocalNotifier.requestAuthorization()
            reopenLastDocumentIfNeeded()
        }

        private func reopenLastDocumentIfNeeded() {
            guard
                NSDocumentController.shared.documents.isEmpty,
                let path = LumaAppState.shared.lastDocumentPath,
                FileManager.default.fileExists(atPath: path)
            else { return }
            let url = URL(fileURLWithPath: path)
            do {
                let docType = try NSDocumentController.shared.typeForContents(of: url)
                let doc = try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: docType)
                NSDocumentController.shared.addDocument(doc)
                doc.makeWindowControllers()
                doc.showWindows()
            } catch {
                FileHandle.standardError.write(Data("[LumaApp] reopen failed: \(error)\n".utf8))
            }
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

#elseif canImport(UIKit)

    import UIKit

    @main
    struct LumaApp: App {
        @UIApplicationDelegateAdaptor(LumaAppDelegate.self) var appDelegate

        var body: some Scene {
            WindowGroup {
                PhoneRootView()
            }
        }
    }

    class LumaAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            application.registerForRemoteNotifications()
            return true
        }


        func application(
            _ application: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            Task { @MainActor in
                APNsRegistration.shared.setToken(deviceToken)
            }
        }

        func application(
            _ application: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Swift.Error
        ) {
            Task { @MainActor in
                APNsRegistration.shared.setError(error.localizedDescription)
            }
        }

        static func handle(url: URL) {
            guard url.scheme == "luma", url.host == "join" else { return }
            guard let labID = labID(from: url) else { return }
            CollaborationJoinQueue.shared.enqueue(labID: labID)
        }

        private static func labID(from url: URL) -> String? {
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

#endif

