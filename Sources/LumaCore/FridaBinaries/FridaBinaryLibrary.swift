import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class FridaBinaryLibrary<Flavor: FridaBinaryFlavor> {
    public private(set) var states: [Flavor: FridaBinaryState] = [:]
    public private(set) var installedVersions: [Flavor: FridaBinaryVersion] = [:]

    private let catalog: FridaReleaseCatalog
    @ObservationIgnored private var downloads: [Flavor: Task<URL, any Swift.Error>] = [:]
    private let directory = URL(fileURLWithPath: GLib.Environment.userCacheDir, isDirectory: true)
        .appendingPathComponent("frida", isDirectory: true)

    public init(catalog: FridaReleaseCatalog) {
        self.catalog = catalog
    }

    public func state(for flavor: Flavor) -> FridaBinaryState {
        if let state = states[flavor] {
            return state
        }
        return (cachedPath(for: flavor) != nil) ? .ready : .missing
    }

    public func installedVersion(for flavor: Flavor) -> FridaBinaryVersion? {
        installedVersions[flavor]
    }

    public func latestVersion(for flavor: Flavor) -> String? {
        catalog.latestVersion(offering: flavor.assetName(version:))
    }

    public func update(for flavor: Flavor) -> FridaBinaryUpdate {
        guard let latest = latestVersion(for: flavor), let installed = installedVersion(for: flavor) else { return .unknown }
        switch installed {
        case .release(let version) where !FridaReleaseCatalog.precedes(version, latest):
            return .upToDate(version: version)
        case .release, .ancient:
            return .available(version: latest)
        }
    }

    public func loadInstalledVersion(for flavor: Flavor) async {
        guard let path = cachedPath(for: flavor) else {
            installedVersions[flavor] = nil
            return
        }
        installedVersions[flavor] = await FridaBinaryVersion.read(from: path)
    }

    public func ensure(_ flavor: Flavor) async throws -> URL {
        if let path = cachedPath(for: flavor) {
            return path
        }
        return try await downloadLatest(flavor)
    }

    @discardableResult
    public func downloadLatest(_ flavor: Flavor) async throws -> URL {
        if let inflight = downloads[flavor] {
            return try await inflight.value
        }
        let download = Task { try await self.download(latestOf: flavor) }
        downloads[flavor] = download
        defer { downloads[flavor] = nil }
        return try await download.value
    }

    public func cachedPath(for flavor: Flavor) -> URL? {
        let path = path(for: flavor)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    private func download(latestOf flavor: Flavor) async throws -> URL {
        await catalog.loadIfNeeded()
        guard let version = latestVersion(for: flavor) else {
            throw FridaBinaryError.noneAvailable(binary: flavor.displayName)
        }
        return try await download(flavor, version: version)
    }

    private func download(_ flavor: Flavor, version: String) async throws -> URL {
        states[flavor] = .downloading(fraction: nil)

        do {
            let destination = path(for: flavor)
            let archive = try await fetch(flavor, version: version)
            try install(archive, at: destination)
            installedVersions[flavor] = await FridaBinaryVersion.read(from: destination)
            states[flavor] = .ready
            return destination
        } catch {
            states[flavor] = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    private func fetch(_ flavor: Flavor, version: String) async throws -> Data {
        let url = URL(string: "https://github.com/frida/frida/releases/download/\(version)/\(flavor.assetName(version: version))")!
        do {
            let downloaded = try await ProgressiveDownload.fetch(url) { [weak self] fraction in
                Task { @MainActor in
                    self?.states[flavor] = .downloading(fraction: fraction)
                }
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            return try Data(contentsOf: downloaded)
        } catch {
            throw FridaBinaryError.downloadFailed(binary: flavor.displayName, version: version, reason: error.localizedDescription)
        }
    }

    private func install(_ archive: Data, at destination: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XZArchive.decompress(archive).write(to: destination, options: .atomic)
    }

    private func path(for flavor: Flavor) -> URL {
        directory.appendingPathComponent(flavor.cachedFileName, isDirectory: false)
    }
}

public enum FridaBinaryState: Sendable, Equatable {
    case missing
    case downloading(fraction: Double?)
    case ready
    case failed(reason: String)

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

public enum FridaBinaryUpdate: Sendable, Equatable {
    case unknown
    case upToDate(version: String)
    case available(version: String)
}

public enum FridaBinaryError: Swift.Error, LocalizedError {
    case noneAvailable(binary: String)
    case downloadFailed(binary: String, version: String, reason: String)
    case decompressionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noneAvailable(let binary):
            return "No published \(binary) found"
        case .downloadFailed(let binary, let version, let reason):
            return "Unable to fetch the \(binary) for Frida \(version): \(reason)"
        case .decompressionFailed(let reason):
            return "Unable to unpack the download: \(reason)"
        }
    }
}
