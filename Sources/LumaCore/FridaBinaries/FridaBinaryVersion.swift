import Foundation
import Frida

public enum FridaBinaryVersion: Sendable, Hashable {
    case release(String)
    case ancient

    public var displayName: String {
        switch self {
        case .release(let version):
            return version
        case .ancient:
            return "ancient"
        }
    }

    static func read(from binary: URL) async -> FridaBinaryVersion {
        await Task.detached(priority: .utility) {
            guard let metadata = try? BinaryMetadata(path: binary.path) else { return .ancient }
            return .release(metadata.version)
        }.value
    }
}
