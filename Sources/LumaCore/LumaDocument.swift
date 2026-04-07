import Foundation

public struct LumaDocument: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        case file(URL)
        case untitled(URL)
    }

    public var storage: Storage

    public var url: URL {
        switch storage {
        case .file(let u), .untitled(let u):
            return u
        }
    }

    public var displayName: String {
        switch storage {
        case .file(let u):
            let name = u.deletingPathExtension().lastPathComponent
            return name.isEmpty ? "Untitled" : name
        case .untitled:
            return "Untitled"
        }
    }

    public var isUntitled: Bool {
        if case .untitled = storage { return true }
        return false
    }

    public var sqlitePath: String { url.path }

    public init(storage: Storage) {
        self.storage = storage
    }
}

public enum LumaDocumentError: Error {
    case invalidPath(URL)
    case copyFailed(URL, URL, Error)
}

public enum LumaDocumentLoader {
    public static let fileExtension = "luma"

    public static func open(at url: URL) throws -> LumaDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LumaDocumentError.invalidPath(url)
        }
        return LumaDocument(storage: .file(url))
    }

    public static func makeUntitled(in directory: URL) throws -> LumaDocument {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let url: URL = {
            for index in 0..<4096 {
                let name = index == 0 ? "Untitled.luma" : "Untitled \(index).luma"
                let candidate = directory.appendingPathComponent(name)
                if !fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return directory.appendingPathComponent("Untitled-\(UUID().uuidString).luma")
        }()

        return LumaDocument(storage: .untitled(url))
    }

    public static func saveAs(
        _ document: LumaDocument,
        to destination: URL
    ) throws -> LumaDocument {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: document.url, to: destination)
        } catch {
            throw LumaDocumentError.copyFailed(document.url, destination, error)
        }
        return LumaDocument(storage: .file(destination))
    }
}
