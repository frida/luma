import Foundation

public enum HostCodeOrigin: Sendable, Equatable {
    case project
    case folder(path: String)
    case labMember(name: String)
    case mission
}

extension HostCodeOrigin {
    public static let request = "This instrument wants to run its own code inside Luma."
    public static let allowLabel = "Allow"

    public var provenance: String {
        switch self {
        case .project:
            "It came with this project."
        case .folder(let path):
            "It comes from the folder \(path)."
        case .labMember(let name):
            "\(name) added or changed it in the lab."
        case .mission:
            "A mission wrote it."
        }
    }
}

public enum CustomInstrumentAuthor: Sendable {
    case localUser
    case mission
}

@MainActor
final class HostCodeTrust {
    enum Decision: Sendable, Equatable {
        case allowed
        case ask(HostCodeOrigin)
    }

    private enum LocalEdit {
        case written
        case editedFrom(String)
    }

    private let catalog: StoreCatalog
    private var origins: [UUID: HostCodeOrigin] = [:]
    private var localEdits: [String: LocalEdit] = [:]

    init(catalogURL: URL) {
        catalog = StoreCatalog(baseURL: catalogURL)
    }

    func decide(_ hostCode: HostCode, ofCustomInstrument defID: UUID) async -> Decision {
        if await isTrusted(hostCode.digest) {
            return .allowed
        }
        return .ask(origins[defID] ?? .project)
    }

    func approve(_ digest: String) {
        LumaAppState.shared.approveHostCode(digest)
    }

    func noteArrival(ofCustomInstrument defID: UUID, from origin: HostCodeOrigin) {
        origins[defID] = origin
    }

    func noteEdit(ofCustomInstrument defID: UUID, from previous: HostCode?, to next: HostCode?, by author: CustomInstrumentAuthor) {
        guard let next, next != previous else { return }
        switch author {
        case .localUser:
            localEdits[next.digest] = previous.map { LocalEdit.editedFrom($0.digest) } ?? .written
        case .mission:
            origins[defID] = .mission
        }
    }

    private func isTrusted(_ digest: String) async -> Bool {
        if LumaAppState.shared.isHostCodeApproved(digest) || isPristineStoreInstallation(digest) {
            return true
        }
        switch localEdits[digest] {
        case .written:
            approve(digest)
            return true
        case .editedFrom(let previous):
            guard await isTrusted(previous) else { return false }
            approve(digest)
            return true
        case nil:
            guard let releases = try? await catalog.publishedItems(withHostCode: digest) else { return false }
            return !releases.isEmpty
        }
    }

    private func isPristineStoreInstallation(_ digest: String) -> Bool {
        LumaAppState.shared.storeInstallations.values.contains { $0.hostCodeDigest == digest }
    }
}
