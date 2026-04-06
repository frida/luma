import Combine
import Foundation
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

final class LumaProject: ReferenceFileDocument, ObservableObject {
    let store: ProjectStore

    nonisolated static var readableContentTypes: [UTType] {
        [UTType(importedAs: "re.frida.luma-project")]
    }
    nonisolated static var writableContentTypes: [UTType] {
        [UTType(importedAs: "re.frida.luma-project")]
    }

    private let packageURL: URL

    init() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("re.frida.Luma.\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("project.sqlite").path
        self.store = try! ProjectStore(path: dbPath)
        self.packageURL = tempDir
    }

    required nonisolated init(configuration: ReadConfiguration) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("re.frida.Luma.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("project.sqlite")

        if let dbWrapper = configuration.file.fileWrappers?["project.sqlite"],
            let data = dbWrapper.regularFileContents
        {
            try data.write(to: dbPath)
        }

        self.store = try ProjectStore(path: dbPath.path)
        self.packageURL = tempDir
    }

    nonisolated func snapshot(contentType: UTType) throws -> PackageSnapshot {
        let dbPath = packageURL.appendingPathComponent("project.sqlite")
        let data = try Data(contentsOf: dbPath)
        return PackageSnapshot(sqliteData: data)
    }

    nonisolated func fileWrapper(snapshot: PackageSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let dir: FileWrapper
        if let existing = configuration.existingFile {
            dir = existing
            dir.fileWrappers?
                .filter { $0.key == "project.sqlite" }
                .forEach { dir.removeFileWrapper($0.value) }
        } else {
            dir = FileWrapper(directoryWithFileWrappers: [:])
        }

        dir.addRegularFile(
            withContents: snapshot.sqliteData,
            preferredFilename: "project.sqlite"
        )

        return dir
    }

    struct PackageSnapshot: Sendable {
        let sqliteData: Data
    }
}
