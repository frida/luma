import Foundation

public struct HookPack: Sendable {
    public let manifest: HookPackManifest
    public let folderURL: URL

    public init(manifest: HookPackManifest, folderURL: URL) {
        self.manifest = manifest
        self.folderURL = folderURL
    }

    public var entryURL: URL {
        folderURL.appendingPathComponent(manifest.entry)
    }
}
