import Foundation
import Observation

@Observable
@MainActor
public final class PatternLibrary {
    public private(set) var sources: [PatternSource] = []

    public let directory: URL

    @ObservationIgnored
    var onChange: (() -> Void)?

    public init(directory: URL) {
        self.directory = directory
    }

    public func reload() {
        sources = discover()
        onChange?()
    }

    public func source(withID id: String) -> PatternSource? {
        sources.first { $0.id == id }
    }

    @discardableResult
    public func create(named name: String, kind: PatternSource.Kind) throws -> PatternSource {
        let url = directory.appendingPathComponent(name).appendingPathExtension(kind.fileExtension)
        try ensureVacant(url)
        try kind.template.write(to: url, atomically: true, encoding: .utf8)
        return reloaded(url)
    }

    @discardableResult
    public func importFile(at url: URL) throws -> PatternSource {
        guard PatternSource.extensions.contains(url.pathExtension.lowercased()) else {
            throw PatternLibraryError.unsupportedFile(url.lastPathComponent)
        }
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try ensureVacant(destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return reloaded(destination)
    }

    public func write(_ text: String, to id: String) throws {
        try text.write(to: directory.appendingPathComponent(id), atomically: true, encoding: .utf8)
        reload()
    }

    @discardableResult
    public func rename(_ id: String, to name: String) throws -> PatternSource {
        let url = directory.appendingPathComponent(id)
        let destination = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        try ensureVacant(destination)
        try FileManager.default.moveItem(at: url, to: destination)
        return reloaded(destination)
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id))
        reload()
    }

    private func ensureVacant(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw PatternLibraryError.alreadyExists(url.lastPathComponent)
        }
    }

    private func reloaded(_ url: URL) -> PatternSource {
        reload()
        return source(withID: relativePath(of: url))!
    }

    private func discover() -> [PatternSource] {
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [PatternSource] = []
        for case let url as URL in entries {
            guard PatternSource.extensions.contains(url.pathExtension.lowercased()),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                continue
            }
            found.append(PatternSource(id: relativePath(of: url), name: url.deletingPathExtension().lastPathComponent, url: url, text: text))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func relativePath(of url: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(of: directory.standardizedFileURL.path + "/", with: "")
    }
}

public struct PatternSource: Identifiable, Hashable, Sendable {
    public static let extensions: Set<String> = ["hexpat", "pat"]

    public let id: String
    public let name: String
    public let url: URL
    public let text: String

    public var kind: Kind {
        url.pathExtension.lowercased() == "pat" ? .library : .pattern
    }

    public enum Kind: Sendable {
        case pattern
        case library

        public var fileExtension: String {
            switch self {
            case .pattern:
                return "hexpat"
            case .library:
                return "pat"
            }
        }

        var template: String {
            switch self {
            case .pattern:
                return "struct Header {\n    u32 magic;\n};\n\nHeader header @ 0x00;\n"
            case .library:
                return "namespace shared {\n\n}\n"
            }
        }
    }
}

public enum PatternLibraryError: LocalizedError {
    case alreadyExists(String)
    case unsupportedFile(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "\(name) already exists."
        case .unsupportedFile(let name):
            return "\(name) is not a .hexpat or .pat file."
        }
    }
}
