import Combine
import Foundation
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

nonisolated final class LumaProject: ReferenceFileDocument {
    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()
    let store: ProjectStore

    nonisolated static var readableContentTypes: [UTType] {
        [UTType.project]
    }
    nonisolated static var writableContentTypes: [UTType] {
        [UTType.project]
    }

    private let temporaryDirectory: URL
    private let temporaryDBURL: URL

    init() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("re.frida.Luma.\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("project.sqlite")
        self.temporaryDirectory = tempDir
        self.temporaryDBURL = dbURL
        self.store = try! ProjectStore(path: dbURL.path)
    }

    required nonisolated init(configuration: ReadConfiguration) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("re.frida.Luma.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("project.sqlite")

        if let data = configuration.file.regularFileContents {
            try data.write(to: dbURL)
        }

        self.temporaryDirectory = tempDir
        self.temporaryDBURL = dbURL
        self.store = try ProjectStore(path: dbURL.path)
    }

    nonisolated func snapshot(contentType: UTType) throws -> Data {
        try Data(contentsOf: temporaryDBURL)
    }

    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}

extension UTType {
    nonisolated static var project: UTType {
        UTType(exportedAs: "re.frida.luma")
    }
}
