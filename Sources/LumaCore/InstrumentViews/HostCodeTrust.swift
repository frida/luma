import Foundation

public enum HostCodeOrigin: Sendable, Equatable {
    case project
    case folder(path: String)
    case labMember(name: String)
    case mission
}

extension HostCodeOrigin {
    var storedJSON: String {
        let object: [String: String] = switch self {
        case .project: ["kind": "project"]
        case .folder(let path): ["kind": "folder", "path": path]
        case .labMember(let name): ["kind": "lab_member", "name": name]
        case .mission: ["kind": "mission"]
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    init?(storedJSON: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? [String: String] else { return nil }
        switch (object["kind"], object["path"], object["name"]) {
        case ("project", _, _): self = .project
        case ("folder", let path?, _): self = .folder(path: path)
        case ("lab_member", _, let name?): self = .labMember(name: name)
        case ("mission", _, _): self = .mission
        default: return nil
        }
    }
}

extension HostCodeOrigin {
    public static let request = "This instrument wants to run its own code inside Luma."
    public static let allowLabel = "Allow"
    public static let gateNote = "Nothing of this instrument runs until you allow it."

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
    private var localEdits: [String: LocalEdit] = [:]

    init(catalogURL: URL) {
        catalog = StoreCatalog(baseURL: catalogURL)
    }

    func decide(_ hostCode: HostCode, origin: HostCodeOrigin) async -> Decision {
        if await isTrusted(hostCode.digest) {
            return .allowed
        }
        return .ask(origin)
    }

    func approve(_ digest: String) {
        LumaAppState.shared.approveHostCode(digest)
    }

    func noteLocalEdit(from previous: HostCode?, to next: HostCode?) {
        guard let next, next != previous else { return }
        localEdits[next.digest] = previous.map { LocalEdit.editedFrom($0.digest) } ?? .written
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
