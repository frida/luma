import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LumaProject: FileDocument {
    static let readableContentTypes: [UTType] = [UTType(exportedAs: "re.frida.luma")]
    static let writableContentTypes: [UTType] = readableContentTypes

    var temporaryDBURL: URL

    init() {
        self.temporaryDBURL = Self.makeTemporaryDBURL()
    }

    init(configuration: ReadConfiguration) throws {
        self.temporaryDBURL = Self.makeTemporaryDBURL()
        if let data = configuration.file.regularFileContents {
            try data.write(to: temporaryDBURL)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Data(contentsOf: temporaryDBURL))
    }

    private static func makeTemporaryDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("re.frida.Luma.\(UUID().uuidString).luma")
    }
}
