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

        try Self.snapshotProject(from: workingProjectURL, to: staging)
        return try FileWrapper(url: staging, options: .immediate)
    }

    static func writeSnapshot(workingURL: URL, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-save-\(UUID().uuidString).luma", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try snapshotProject(from: workingURL, to: staging)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: destination)
        }
    }

    private static func snapshotProject(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let dbSource = source.appendingPathComponent("db.sqlite")
        let dbDest = destination.appendingPathComponent("db.sqlite")
        try ProjectStore.exportSnapshot(from: dbSource, to: dbDest)

        let tracesSource = source.appendingPathComponent("traces", isDirectory: true)
        let tracesDest = destination.appendingPathComponent("traces", isDirectory: true)
        if fm.fileExists(atPath: tracesSource.path) {
            try fm.copyItem(at: tracesSource, to: tracesDest)
        }
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
        let fm = FileManager.default
        let dir = LumaAppPaths.shared.untitledDirectory.appendingPathComponent(".working", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Working-\(UUID().uuidString).luma")
    }
}
