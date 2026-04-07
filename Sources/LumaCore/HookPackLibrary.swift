import Foundation
import Observation

@Observable
@MainActor
public final class HookPackLibrary {
    public private(set) var packs: [HookPack] = []

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        reload()
    }

    public func reload() {
        packs = discover()
    }

    public func pack(withId id: String) -> HookPack? {
        packs.first { $0.manifest.id == id }
    }

    public func descriptors() -> [InstrumentDescriptor] {
        packs.map { pack in
            let icon: InstrumentIcon
            if let iconMeta = pack.manifest.icon {
                if let file = iconMeta.file {
                    icon = .file(pack.folderURL.appendingPathComponent(file))
                } else if let system = iconMeta.systemName {
                    icon = .system(system)
                } else {
                    icon = .system("puzzlepiece.extension")
                }
            } else {
                icon = .system("puzzlepiece.extension")
            }

            let packID = pack.manifest.id
            let defaultEnabled = Dictionary(
                uniqueKeysWithValues: pack.manifest.features
                    .filter(\.defaultEnabled)
                    .map { ($0.id, FeatureConfig()) }
            )

            return InstrumentDescriptor(
                id: "hook-pack:\(packID)",
                kind: .hookPack,
                sourceIdentifier: packID,
                displayName: pack.manifest.name,
                icon: icon,
                makeInitialConfigJSON: {
                    try! JSONEncoder().encode(
                        HookPackConfig(packId: packID, features: defaultEnabled)
                    )
                }
            )
        }
    }

    private func discover() -> [HookPack] {
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

        var result: [HookPack] = []
        for url in contents {
            guard
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                rv.isDirectory == true
            else { continue }

            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }

            do {
                let manifest = try JSONDecoder().decode(HookPackManifest.self, from: data)
                result.append(HookPack(manifest: manifest, folderURL: url))
            } catch {
                print("Failed to decode hook-pack manifest at \(manifestURL): \(error)")
            }
        }

        return result
    }
}
