import Foundation
import Observation

@Observable
@MainActor
public final class InstrumentFolderLibrary {
    public private(set) var folders: [InstrumentFolder] = []

    @ObservationIgnored public var onError: ((String) -> Void)?

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func reload() {
        folders = discover()
    }

    private func discover() -> [InstrumentFolder] {
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var result: [InstrumentFolder] = []
        for url in contents {
            let manifestURL = url.appendingPathComponent(InstrumentFolder.manifestFileName)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            do {
                result.append(try InstrumentFolder(folderURL: url))
            } catch {
                onError?("Failed to read instrument manifest at \(manifestURL.path): \(error)")
            }
        }

        return result
    }
}
