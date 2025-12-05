import Foundation

@MainActor
final class InstrumentMetadataRegistry {
    static let shared = InstrumentMetadataRegistry()

    private init() {}

    func displayName(for instance: InstrumentInstance) -> String {
        switch instance.kind {
        case .tracer:
            return "Tracer"
        case .hookPack:
            if let pack = HookPackLibrary.shared.pack(withId: instance.sourceIdentifier) {
                return pack.manifest.name
            }
            return "Hook-Pack \(instance.sourceIdentifier)"
        case .codeShare:
            if let cfg = try? JSONDecoder().decode(
                CodeShareConfig.self,
                from: instance.configJSON
            ) {
                return cfg.name
            }
            return "CodeShare \(instance.sourceIdentifier)"
        }
    }

    func icon(for instance: InstrumentInstance) -> InstrumentIcon {
        switch instance.kind {
        case .tracer:
            return .system("arrow.triangle.branch")
        case .hookPack:
            if let pack = HookPackLibrary.shared.pack(withId: instance.sourceIdentifier) {
                if let iconMeta = pack.manifest.icon {
                    if let file = iconMeta.file {
                        return .file(pack.folderURL.appendingPathComponent(file))
                    } else if let system = iconMeta.systemName {
                        return .system(system)
                    }
                }
            }
            return .system("puzzlepiece.extension")
        case .codeShare:
            return .system("cloud")
        }
    }
}
