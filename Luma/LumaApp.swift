import Combine
import Frida
import LumaCore
import SwiftUI
import SwiftyMonaco
import UniformTypeIdentifiers

@MainActor
let sharedWelcomeModel = WelcomeModel(dataDirectory: LumaAppPaths.shared.dataDirectory)

@MainActor
func sharedGitHubAuth() -> GitHubAuth { sharedWelcomeModel.gitHubAuth }

#if os(macOS)

    @main
    struct LumaApp: App {
        @NSApplicationDelegateAdaptor(LumaAppDelegate.self) var appDelegate
        @StateObject private var updater = LumaUpdater()

        init() {
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaCodeShare()), count: 2)
            SwiftyMonaco.prewarmPool(profile: MonacoEditorProfile(from: EditorProfile.fridaTracerHook(packages: [])), count: 2)
            MainActor.assumeIsolated {
                InstrumentUIRegistry.shared.registerGlobalDefaults()
            }
        }

        var body: some Scene {
            Window("Luma", id: WelcomeWindow.id) {
                WelcomeWindow(welcome: sharedWelcomeModel)
            }
            .defaultSize(width: 560, height: 720)
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)

            DocumentGroup(newDocument: LumaProject()) { configuration in
                MainWindowView(
                    document: configuration.$document,
                    fileURL: configuration.fileURL
                )
            }
            .defaultSize(width: 1100, height: 680)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Luma") { showAboutPanel() }
                }
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesView(updater: updater)
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Project") {
                        NSDocumentController.shared.newDocument(nil)
                    }
                    .keyboardShortcut("n", modifiers: [.command])

                    Button("Open Project\u{2026}") {
                        NSDocumentController.shared.openDocument(nil)
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                }
            }
        }
    }

    @MainActor
    private func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: nowSecureCreditsAttributedString()
        ])
    }

    @MainActor
    private func nowSecureCreditsAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let prefix = NSAttributedString(
            string: "Sponsored by ",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        result.append(prefix)

        let link = NSAttributedString(
            string: "NowSecure",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .link: URL(string: "https://www.nowsecure.com")!,
                .paragraphStyle: paragraph,
            ]
        )
        result.append(link)
        return result
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
            Task { @MainActor in
                await sharedWelcomeModel.bootstrap()
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
            if let labID = BackendConfig.labID(fromInviteLink: url) {
                CollaborationJoinQueue.shared.enqueue(labID: labID)
                return
            }

            guard url.scheme == "luma", url.host == "join",
                let labID = labID(from: url)
            else {
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

        init() {
            MainActor.assumeIsolated {
                InstrumentUIRegistry.shared.registerGlobalDefaults()
            }
        }

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
            if let labID = BackendConfig.labID(fromInviteLink: url) {
                CollaborationJoinQueue.shared.enqueue(labID: labID)
                return
            }
            guard url.scheme == "luma", url.host == "join",
                let labID = labID(from: url)
            else { return }
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

