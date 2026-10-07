import Foundation
import Observation

@Observable
@MainActor
public final class PatternLibrary {
    public nonisolated static let packageKeyword = "frida-pattern"

    public private(set) var projectSources: [PatternSource] = []
    public private(set) var packageSources: [PatternSource] = []

    public let directory: URL

    @ObservationIgnored
    var onChange: (() -> Void)?

    private let store: ProjectStore
    private let workspace: CompilerWorkspacePaths

    public init(store: ProjectStore, workspace: CompilerWorkspacePaths) {
        self.store = store
        self.workspace = workspace
        directory = Self.directory(in: workspace)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func directory(in workspace: CompilerWorkspacePaths) -> URL {
        workspace.root.appendingPathComponent("patterns", isDirectory: true)
    }

    public var sources: [PatternSource] {
        projectSources + packageSources
    }

    public func reload() {
        let records = (try? store.fetchPatternSources()) ?? []
        try? materialize(records)
        projectSources = records.map(projectSource(for:))
        packageSources = installedPatternPackages()
        onChange?()
    }

    public func source(withID id: String) -> PatternSource? {
        sources.first { $0.id == id }
    }

    @discardableResult
    public func create(named name: String, kind: PatternSource.Kind) throws -> PatternSource {
        try create(named: name, kind: kind, text: kind.template)
    }

    @discardableResult
    public func create(named name: String, kind: PatternSource.Kind, text: String) throws -> PatternSource {
        try add(PatternSourceRecord(name: name, kind: kind, text: text))
    }

    @discardableResult
    public func importFile(at url: URL) throws -> PatternSource {
        guard let kind = PatternSource.Kind(path: url.path) else {
            throw PatternLibraryError.unsupportedFile(url.lastPathComponent)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try add(PatternSourceRecord(name: url.deletingPathExtension().lastPathComponent, kind: kind, text: text))
    }

    @discardableResult
    public func copyToProject(_ id: String) throws -> PatternSource {
        guard let source = source(withID: id) else {
            throw PatternLibraryError.notFound(id)
        }
        return try add(PatternSourceRecord(name: source.name, kind: source.kind, text: source.text))
    }

    public func write(_ text: String, to id: String) throws {
        var record = try editableRecord(id)
        record.text = text
        record.updatedAt = .now
        try store.save(record)
        reload()
    }

    @discardableResult
    public func rename(_ id: String, to name: String) throws -> PatternSource {
        var record = try editableRecord(id)
        record.name = name
        record.updatedAt = .now
        try ensureVacant(record.fileName, except: record.id)
        try store.save(record)
        reload()
        return source(withID: id)!
    }

    public func delete(_ id: String) throws {
        let record = try editableRecord(id)
        try store.deletePatternSource(id: record.id)
        reload()
    }

    private func add(_ record: PatternSourceRecord) throws -> PatternSource {
        try ensureVacant(record.fileName, except: record.id)
        try store.save(record)
        reload()
        return source(withID: record.id.uuidString)!
    }

    private func editableRecord(_ id: String) throws -> PatternSourceRecord {
        guard let uuid = UUID(uuidString: id), let record = try store.fetchPatternSource(id: uuid) else {
            throw PatternLibraryError.readOnly(source(withID: id)?.name ?? id)
        }
        return record
    }

    private func ensureVacant(_ fileName: String, except id: UUID) throws {
        let taken = try store.fetchPatternSources().contains { $0.id != id && $0.fileName == fileName }
        if taken {
            throw PatternLibraryError.alreadyExists(fileName)
        }
    }

    private func projectSource(for record: PatternSourceRecord) -> PatternSource {
        let url = directory.appendingPathComponent(record.fileName)
        return PatternSource(
            id: record.id.uuidString, name: record.name, kind: record.kind, origin: .project, url: url,
            workspacePath: workspacePath(of: url), text: record.text)
    }

    private func materialize(_ records: [PatternSourceRecord]) throws {
        let fm = FileManager.default
        var wanted = Set<String>()
        for record in records {
            wanted.insert(record.fileName)
            let url = directory.appendingPathComponent(record.fileName)
            let content = Data(record.text.utf8)
            if fm.contents(atPath: url.path) == content { continue }
            try content.write(to: url)
        }
        for name in try fm.contentsOfDirectory(atPath: directory.path) where !wanted.contains(name) && !name.hasPrefix(".") {
            try fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func installedPatternPackages() -> [PatternSource] {
        let installed = (try? store.fetchPackagesState().packages) ?? []
        return installed.compactMap { package in
            guard let manifest = PatternPackageManifest.of(package, in: workspace), let kind = PatternSource.Kind(path: manifest.main)
            else {
                return nil
            }
            let url = workspace.nodeModules.appendingPathComponent(package.name, isDirectory: true).appendingPathComponent(manifest.main)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            return PatternSource(
                id: "package:" + package.name, name: url.deletingPathExtension().lastPathComponent, kind: kind,
                origin: .package(package.name), url: url, workspacePath: workspacePath(of: url), text: text)
        }
    }

    private func workspacePath(of url: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(of: workspace.root.standardizedFileURL.path + "/", with: "")
    }
}

public struct PatternSource: Identifiable, Hashable, Sendable {
    public static let extensions: Set<String> = ["hexpat", "pat"]

    public let id: String
    public let name: String
    public let kind: Kind
    public let origin: Origin
    public let url: URL
    public let workspacePath: String
    public let text: String

    public var fileName: String {
        url.lastPathComponent
    }

    public enum Origin: Hashable, Sendable {
        case project
        case package(String)
    }

    public enum Kind: String, Codable, Sendable {
        case pattern = "hexpat"
        case library = "pat"

        public init?(path: String) {
            self.init(rawValue: (path as NSString).pathExtension.lowercased())
        }

        public var fileExtension: String {
            rawValue
        }

        public var template: String {
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
    case notFound(String)
    case readOnly(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "\(name) already exists."
        case .unsupportedFile(let name):
            return "\(name) is not a .hexpat or .pat file."
        case .notFound(let id):
            return "There is no pattern \(id)."
        case .readOnly(let name):
            return "\(name) comes from a package and cannot be changed; copy it into the project first."
        }
    }
}
