import Foundation
import Observation

@Observable
@MainActor
public final class PatternLibrary {
    public private(set) var sources: [PatternSource] = []

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func reload() {
        sources = discover()
    }

    public func source(withID id: String) -> PatternSource? {
        sources.first { $0.id == id }
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
            let relativePath = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            found.append(PatternSource(id: relativePath, name: url.deletingPathExtension().lastPathComponent, url: url, text: text))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public struct PatternSource: Identifiable, Hashable, Sendable {
    public static let extensions: Set<String> = ["hexpat", "pat"]

    public let id: String
    public let name: String
    public let url: URL
    public let text: String
}
