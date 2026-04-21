import Foundation
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct LumaProject: FileDocument {
    static let readableContentTypes: [UTType] = [UTType(exportedAs: "re.frida.luma")]
    static let writableContentTypes: [UTType] = readableContentTypes

    var workingDBURL: URL
    var revision: Int = 0

    init() {
        let doc = (try? LumaDocumentLoader.makeUntitled(in: LumaAppPaths.shared.untitledDirectory))
            ?? LumaDocument(storage: .untitled(
                LumaAppPaths.shared.untitledDirectory
                    .appendingPathComponent("Untitled-\(UUID().uuidString).luma")
            ))
        self.workingDBURL = doc.url
        Self.ensureFileExists(at: workingDBURL)
    }

    init(configuration: ReadConfiguration) throws {
        self.workingDBURL = Self.uniqueWorkingCopyURL()
        let data = configuration.file.regularFileContents ?? Data()
        try data.write(to: workingDBURL)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-save-\(UUID().uuidString).luma")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try ProjectStore.exportSnapshot(from: workingDBURL, to: staging)
            let data = try Data(contentsOf: staging)
            return FileWrapper(regularFileWithContents: data)
        } catch {
            let fallback = (try? Data(contentsOf: workingDBURL)) ?? Data()
            return FileWrapper(regularFileWithContents: fallback)
        }
    }

    private static func ensureFileExists(at url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
    }

    private static func uniqueWorkingCopyURL() -> URL {
        let fm = FileManager.default
        let dir = LumaAppPaths.shared.untitledDirectory.appendingPathComponent(".working", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Working-\(UUID().uuidString).luma")
    }
}
