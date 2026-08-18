import Foundation
import Observation

/// What a template needs to boot before anybody has anything of their own: a
/// known-good set of files, fetched once and remembered, filling the
/// parameters the user would otherwise have to go and find.
public struct StarterImages: Sendable, Equatable {
    public let name: String
    public let files: [StarterImageFile]

    public init(name: String, files: [StarterImageFile]) {
        self.name = name
        self.files = files
    }
}

public struct StarterImageFile: Sendable, Equatable {
    public let parameterID: String
    public let url: URL
    public let storedAs: String
    public let packaging: StarterImagePackaging

    public init(parameterID: String, url: URL, storedAs: String, packaging: StarterImagePackaging = .plain) {
        self.parameterID = parameterID
        self.url = url
        self.storedAs = storedAs
        self.packaging = packaging
    }
}

public enum StarterImagePackaging: Sendable, Equatable {
    case plain
    case gzip
    /// However the distribution wrapped its kernel, what gets stored is the
    /// bare image the framework boots.
    case linuxKernel
}

public enum StarterImageState: Sendable, Equatable {
    case missing
    case downloading
    case ready
    case failed(reason: String)
}

@Observable
@MainActor
public final class StarterImageLibrary {
    public private(set) var states: [String: StarterImageState] = [:]

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func state(for images: StarterImages) -> StarterImageState {
        if let state = states[images.name] {
            return state
        }
        return cachedPaths(for: images) != nil ? .ready : .missing
    }

    public func cachedPaths(for images: StarterImages) -> [String: URL]? {
        var paths: [String: URL] = [:]
        for file in images.files {
            let path = self.path(for: file)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            paths[file.parameterID] = path
        }
        return paths
    }

    public func download(_ images: StarterImages) async throws -> [String: URL] {
        states[images.name] = .downloading

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var paths: [String: URL] = [:]
            for file in images.files {
                paths[file.parameterID] = try await fetch(file)
            }
            states[images.name] = .ready
            return paths
        } catch {
            states[images.name] = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    private func fetch(_ file: StarterImageFile) async throws -> URL {
        let destination = path(for: file)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return destination }

        let (downloaded, response) = try await URLSession.shared.download(from: file.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StarterImageError.downloadFailed(url: file.url)
        }

        switch file.packaging {
        case .plain:
            try FileManager.default.moveItem(at: downloaded, to: destination)
        case .gzip:
            try GzipArchive.decompress(downloaded, to: destination)
            try? FileManager.default.removeItem(at: downloaded)
        case .linuxKernel:
            let packed = try Data(contentsOf: downloaded, options: .mappedIfSafe)
            try LinuxKernelImage.raw(from: packed).write(to: destination)
            try? FileManager.default.removeItem(at: downloaded)
        }
        return destination
    }

    private func path(for file: StarterImageFile) -> URL {
        directory.appendingPathComponent(file.storedAs, isDirectory: false)
    }
}

public enum StarterImageError: Swift.Error, LocalizedError {
    case downloadFailed(url: URL)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):
            return "Unable to download \(url.lastPathComponent)"
        }
    }
}
