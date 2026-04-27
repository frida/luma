#if os(macOS)

import AppKit
import LumaCore
import SwiftUI

struct WelcomeWindow: View {
    static let id = "welcome"

    @Environment(\.dismissWindow) private var dismissWindow
    let welcome: WelcomeModel

    var body: some View {
        WelcomeView(
            welcome: welcome,
            onCreateBlank: createBlank,
            onOpenExisting: openExisting,
            onCreateFromLab: createFromLab
        )
        .frame(width: 470)
        .frame(minHeight: 620)
    }

    private func createBlank() {
        NSDocumentController.shared.newDocument(nil)
        dismissAfterOpen()
    }

    private func openExisting() {
        NSDocumentController.shared.openDocument(nil)
        dismissAfterOpen()
    }

    private func createFromLab(_ lab: WelcomeModel.LabSummary) {
        let url = LumaAppPaths.shared.untitledDirectory
            .appendingPathComponent("\(sanitizedFilename(for: lab.title)).luma")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        CollaborationJoinQueue.shared.enqueue(labID: lab.id)
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { _, _, _ in }
        dismissAfterOpen()
    }

    private func dismissAfterOpen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            dismissWindow(id: Self.id)
        }
    }

    private func sanitizedFilename(for title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let trimmed = title.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Lab" : trimmed
    }
}

#endif
