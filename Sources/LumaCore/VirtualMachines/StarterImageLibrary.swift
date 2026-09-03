import Foundation
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a template needs to boot before anybody has anything of their own: a
/// known-good set of files, fetched once and remembered, filling the
/// parameters the user would otherwise have to go and find.
public struct StarterImages: Sendable, Equatable {
    public let name: String
    public let files: [StarterImageFile]
    public let symbols: StarterImageSymbols?

    public init(name: String, files: [StarterImageFile], symbols: StarterImageSymbols? = nil) {
        self.name = name
        self.files = files
        self.symbols = symbols
    }
}

/// Where a distribution keeps the symbols of the kernel it just handed over,
/// named after the version the kernel itself reports.
public struct StarterImageSymbols: Sendable, Equatable {
    public let parameterID: String
    public let describing: String
    public let directory: URL
    public let namePrefix: String
    public let storedAs: String

    public init(parameterID: String, describing: String, directory: URL, namePrefix: String, storedAs: String) {
        self.parameterID = parameterID
        self.describing = describing
        self.directory = directory
        self.namePrefix = namePrefix
        self.storedAs = storedAs
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
    case downloading(fraction: Double?)
    case ready
    case failed(reason: String)

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
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
        states[images.name] = .downloading(fraction: nil)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileCount = images.files.count + (images.symbols == nil ? 0 : 1)
            var completed = 0
            let noteProgress = { [weak self] (name: String, fraction: Double?) in
                self?.states[name] = .downloading(
                    fraction: fraction.map { (Double(completed) + $0) / Double(fileCount) })
            }

            var paths: [String: URL] = [:]
            for file in images.files {
                paths[file.parameterID] = try await fetch(file) { fraction in
                    noteProgress(images.name, fraction)
                }
                completed += 1
            }

            if let symbols = images.symbols, let kernel = paths[symbols.describing] {
                paths[symbols.parameterID] = try await fetchSymbols(symbols, describing: kernel) { fraction in
                    noteProgress(images.name, fraction)
                }
            }

            states[images.name] = .ready
            return paths
        } catch {
            states[images.name] = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    private func fetchSymbols(
        _ symbols: StarterImageSymbols,
        describing kernel: URL,
        reporting report: @escaping @MainActor (Double?) -> Void
    ) async throws -> URL {
        let destination = directory.appendingPathComponent(symbols.storedAs, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return destination }

        let image = try Data(contentsOf: kernel, options: .mappedIfSafe)
        guard let version = LinuxKernelImage.version(of: image) else {
            throw StarterImageError.symbolsUnavailable
        }

        let url = symbols.directory.appendingPathComponent(symbols.namePrefix + version)
        let downloaded = try await download(from: url, reporting: report)

        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    private func fetch(
        _ file: StarterImageFile,
        reporting report: @escaping @MainActor (Double?) -> Void
    ) async throws -> URL {
        let destination = path(for: file)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return destination }

        let downloaded = try await download(from: file.url, reporting: report)

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

    private func download(
        from url: URL,
        reporting report: @escaping @MainActor (Double?) -> Void
    ) async throws -> URL {
        do {
            return try await ProgressiveDownload.fetch(url) { fraction in
                Task { @MainActor in report(fraction) }
            }
        } catch {
            throw StarterImageError.downloadFailed(url: url)
        }
    }

    private func path(for file: StarterImageFile) -> URL {
        directory.appendingPathComponent(file.storedAs, isDirectory: false)
    }
}

public enum StarterImageError: Swift.Error, LocalizedError {
    case downloadFailed(url: URL)
    case symbolsUnavailable

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):
            return "Unable to download \(url.lastPathComponent)"
        case .symbolsUnavailable:
            return "The kernel does not say which version it is, so its symbols cannot be found"
        }
    }
}
