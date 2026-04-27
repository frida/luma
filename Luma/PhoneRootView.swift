#if canImport(UIKit)

import LumaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhoneRootView: View {
    @State private var dbURL: URL?
    @State private var isShowingOpenPicker = false
    @State private var isShowingSaveAsPicker = false
    private var welcome: WelcomeModel { sharedWelcomeModel }
    @State private var isWelcomeOpenPickerVisible = false

    private static let lumaUTI = "re.frida.luma"

    var body: some View {
        Group {
            if let dbURL {
                PhoneMainView(
                    dbURL: dbURL,
                    documentActions: PhoneDocumentActions(
                        currentDisplayName: Self.displayName(for: dbURL),
                        new: returnToWelcome,
                        open: { isShowingOpenPicker = true },
                        saveAs: { isShowingSaveAsPicker = true }
                    )
                )
                .id(dbURL)
            } else {
                WelcomeView(
                    welcome: welcome,
                    onCreateBlank: openFreshUntitled,
                    onOpenExisting: { isWelcomeOpenPickerVisible = true },
                    onCreateFromLab: openFromLab
                )
                .fileImporter(
                    isPresented: $isWelcomeOpenPickerVisible,
                    allowedContentTypes: [UTType(exportedAs: Self.lumaUTI)]
                ) { result in
                    if case .success(let url) = result {
                        importExternal(url)
                    }
                }
            }
        }
        .task(id: "welcome-bootstrap") {
            await welcome.bootstrap()
        }
        .onOpenURL(perform: handleIncomingURL)
        .fileImporter(
            isPresented: $isShowingOpenPicker,
            allowedContentTypes: [UTType(exportedAs: Self.lumaUTI)]
        ) { result in
            if case .success(let url) = result {
                importExternal(url)
            }
        }
        .fileExporter(
            isPresented: $isShowingSaveAsPicker,
            document: dbURL.map(LumaExportDocument.init(sourceURL:)),
            contentType: UTType(exportedAs: Self.lumaUTI),
            defaultFilename: dbURL.map(Self.displayName(for:))
        ) { _ in }
    }

    @MainActor
    private func returnToWelcome() {
        dbURL = nil
        Task { await welcome.refreshLabs() }
    }

    @MainActor
    private func openFromLab(_ lab: WelcomeModel.LabSummary) {
        let url = Self.untitledURL(named: lab.title)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        CollaborationJoinQueue.shared.enqueue(labID: lab.id)
        dbURL = url
        LumaAppState.shared.lastDocumentPath = url.path
    }

    @MainActor
    private func openFreshUntitled() {
        let url = Self.nextUntitledURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        dbURL = url
        LumaAppState.shared.lastDocumentPath = url.path
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "luma" {
            LumaAppDelegate.handle(url: url)
            return
        }
        guard url.isFileURL else { return }
        importExternal(url)
    }

    @MainActor
    private func importExternal(_ sourceURL: URL) {
        if sourceURL.path == dbURL?.path { return }

        let started = sourceURL.startAccessingSecurityScopedResource()
        defer { if started { sourceURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            let destURL = Self.workingCopyURL(for: sourceURL)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
            dbURL = destURL
            LumaAppState.shared.lastDocumentPath = destURL.path
        } catch {
            assertionFailure("Failed to import \(sourceURL.path): \(error)")
        }
    }

    private static func nextUntitledURL() -> URL {
        let dir = LumaAppPaths.shared.untitledDirectory
        let fm = FileManager.default
        for index in 0..<4096 {
            let name = index == 0 ? "Untitled.luma" : "Untitled \(index).luma"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("Untitled-\(UUID().uuidString).luma")
    }

    private static func untitledURL(named rawTitle: String) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = rawTitle.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = sanitized.isEmpty ? "Lab" : sanitized
        let dir = LumaAppPaths.shared.untitledDirectory
        let fm = FileManager.default
        let primary = dir.appendingPathComponent("\(base).luma")
        if !fm.fileExists(atPath: primary.path) {
            return primary
        }
        for index in 1..<4096 {
            let candidate = dir.appendingPathComponent("\(base) \(index).luma")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).luma")
    }

    private static func workingCopyURL(for sourceURL: URL) -> URL {
        let dir = LumaAppPaths.shared.untitledDirectory.appendingPathComponent(".working", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(baseName)-\(UUID().uuidString).luma")
    }

    private static let uuidSuffixPattern = #"-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    private static func displayName(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        if let range = raw.range(of: uuidSuffixPattern, options: .regularExpression) {
            return String(raw[..<range.lowerBound])
        }
        return raw
    }
}

struct PhoneNotebookSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotebookView(workspace: workspace, selection: .constant(nil))
                .navigationTitle("Notebook")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct PhoneDocumentActions {
    let currentDisplayName: String
    let new: () -> Void
    let open: () -> Void
    let saveAs: () -> Void

    static let noop = PhoneDocumentActions(
        currentDisplayName: "",
        new: {},
        open: {},
        saveAs: {}
    )
}

private struct LumaExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [UTType(exportedAs: "re.frida.luma")]

    let sourceURL: URL

    init() {
        self.sourceURL = URL(fileURLWithPath: "/dev/null")
    }

    init(configuration: ReadConfiguration) throws {
        self.sourceURL = URL(fileURLWithPath: "/dev/null")
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-export-\(UUID().uuidString).luma")
        defer { try? FileManager.default.removeItem(at: staging) }

        try ProjectStore.exportSnapshot(from: sourceURL, to: staging)

        let data = try Data(contentsOf: staging)
        return FileWrapper(regularFileWithContents: data)
    }
}

#endif
