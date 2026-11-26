import Foundation
import Observation

@Observable
@MainActor
public final class InstrumentFolderLibrary {
    public private(set) var folders: [InstrumentFolder] = []
    public private(set) var unreadableFolders: [URL: String] = [:]

    @ObservationIgnored public var onError: ((String) -> Void)?

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func reload() {
        (folders, unreadableFolders) = discover()
    }

    private func discover() -> ([InstrumentFolder], [URL: String]) {
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return ([], [:])
        }

        var result: [InstrumentFolder] = []
        var unreadable: [URL: String] = [:]
        for url in contents {
            let manifestURL = url.appendingPathComponent(InstrumentFolder.manifestFileName)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            do {
                result.append(try InstrumentFolder(folderURL: url))
            } catch {
                unreadable[url.standardizedFileURL] = Self.name(declaredIn: manifestURL) ?? url.lastPathComponent
                onError?("Failed to read instrument manifest at \(manifestURL.path): \(error)")
            }
        }

        return (result, unreadable)
    }

    private static func name(declaredIn manifestURL: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: manifestURL.path),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (manifest["displayName"] as? String) ?? (manifest["name"] as? String)
    }
}
