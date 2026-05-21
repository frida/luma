import Foundation
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct LumaProject: FileDocument {
    static let readableContentTypes: [UTType] = [UTType(exportedAs: "re.frida.luma")]
    static let writableContentTypes: [UTType] = readableContentTypes

    var workingProjectURL: URL

    init() {
        let doc = (try? LumaDocumentLoader.makeUntitled(in: LumaAppPaths.shared.untitledDirectory))
            ?? LumaDocument(storage: .untitled(
                LumaAppPaths.shared.untitledDirectory
                    .appendingPathComponent("Untitled-\(UUID().uuidString).luma")
            ))
        self.workingProjectURL = doc.url
        Self.ensureProjectExists(at: workingProjectURL)
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory,
            configuration.file.fileWrappers?["db.sqlite"] != nil
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.workingProjectURL = Self.uniqueWorkingCopyURL()
        try copyFileWrapper(configuration.file, to: workingProjectURL)
        Self.ensureProjectExists(at: workingProjectURL)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-save-\(UUID().uuidString).luma", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try ProjectSnapshot.snapshot(from: workingProjectURL, to: staging)
        return try FileWrapper(url: staging, options: .immediate)
    }

    private func copyFileWrapper(_ wrapper: FileWrapper, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try wrapper.write(to: destination, options: [.atomic, .withNameUpdating], originalContentsURL: nil)
    }

    private static func ensureProjectExists(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? fm.createDirectory(at: url.appendingPathComponent("traces", isDirectory: true), withIntermediateDirectories: true)
    }

    private static func uniqueWorkingCopyURL() -> URL {
        let dir = LumaAppPaths.shared.workingDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Working-\(UUID().uuidString).luma")
    }
}
