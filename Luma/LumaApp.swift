import Combine
import Frida
import SwiftData
import SwiftUI
import SwiftyMonaco
import UniformTypeIdentifiers

#if os(macOS)

    @main
    struct LumaApp: App {
        @NSApplicationDelegateAdaptor(LumaAppDelegate.self) var appDelegate

        init() {
            SwiftyMonaco.prewarmPool(profile: CodeShareEditorProfile.javascript, count: 2)
            SwiftyMonaco.prewarmPool(profile: TracerEditorProfile.typescript, count: 2)

            HookPackLibrary.shared.reload()
        }

        var body: some Scene {
            DocumentGroup(editing: .project, migrationPlan: LumaMigrationPlan.self) {
                MainWindowView()
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

            CollaborationJoinCoordinator.shared.enqueue(roomID: roomID)

            do {
                try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            } catch {
                NSLog("Failed to open untitled document for collaboration link: \(error)")
            }
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
            SwiftyMonaco.prewarmPool(profile: CodeShareEditorProfile.javascript, count: 2)
            SwiftyMonaco.prewarmPool(profile: TracerEditorProfile.typescript, count: 2)
            HookPackLibrary.shared.reload()
        }

        var body: some Scene {
            DocumentGroup(editing: .project, migrationPlan: LumaMigrationPlan.self) {
                MainWindowView()
            }
        }
    }

#endif

final class CollaborationJoinCoordinator: ObservableObject {
    static let shared = CollaborationJoinCoordinator()

    private var pendingRoomIDs: [String] = []

    func enqueue(roomID: String) {
        pendingRoomIDs.append(roomID)
    }

    func consumeNextRoomID() -> String? {
        guard !pendingRoomIDs.isEmpty else { return nil }
        return pendingRoomIDs.removeFirst()
    }
}

extension UTType {
    static var project: UTType {
        UTType(importedAs: "re.frida.luma-project")
    }
}

struct LumaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [VersionedSchema.Type] = [
        LumaVersionedSchema.self
    ]

    static let stages: [MigrationStage] = []
}

struct LumaVersionedSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        ProjectUIState.self,
        ProjectPackagesState.self,
        InstalledPackage.self,
        ProjectCollaborationState.self,
        NotebookEntry.self,
        TargetPickerState.self,
        ProcessSession.self,
        RemoteDeviceConfig.self,
        REPLCell.self,
    ]
}
