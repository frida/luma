import Foundation
import Observation

@Observable
@MainActor
final class InstalledStoreItems {
    private(set) var installations: [StoreItem.ID: StoreInstallation] = [:]
    private(set) var items: [StoreItem] = []

    @ObservationIgnored private let library: InstrumentFolderLibrary

    init(library: InstrumentFolderLibrary) {
        self.library = library
    }

    var isEmpty: Bool {
        installations.isEmpty
    }

    func reconcile() {
        let appState = LumaAppState.shared
        let uninstalledBehindOurBack = appState.storeInstallations.keys.filter {
            !FileManager.default.fileExists(atPath: folderURL(for: $0).path)
        }
        for itemID in uninstalledBehindOurBack {
            appState.setStoreInstallation(nil, forItemID: itemID)
        }
        installations = appState.storeInstallations
        items.removeAll { installations[$0.id] == nil }
    }

    func adopt(_ answer: [StoreItem], askedAbout askedIDs: Set<StoreItem.ID>) {
        let learnedSinceAsking = items.filter { !askedIDs.contains($0.id) }
        items = answer.filter { installations[$0.id] != nil }.map(newestKnown) + learnedSinceAsking
    }

    func linkedInstallation(at folderURL: URL) -> Storefront.LinkedInstallation? {
        let path = folderURL.standardizedFileURL.path
        guard let installation = installations.values.first(where: { self.folderURL(for: $0.itemID).standardizedFileURL.path == path })
        else { return nil }
        return Storefront.LinkedInstallation(
            itemID: installation.itemID,
            installedVersion: installation.version,
            latest: latest(of: installation)
        )
    }

    func folderURL(for itemID: StoreItem.ID) -> URL {
        library.directory.appendingPathComponent(itemID.replacingOccurrences(of: "/", with: "."), isDirectory: true)
    }

    func holdsLocalChanges(itemID: StoreItem.ID, linkedCopy: InstrumentFolderLink.Snapshot?) -> Bool {
        let folderURL = folderURL(for: itemID)
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return false }
        guard let installation = installations[itemID] else { return true }
        let isFolderEdited = isEdited(folderURL, since: installation.snapshot)
        let isLinkedCopyEdited = linkedCopy != nil && linkedCopy != installation.snapshot
        return isFolderEdited || isLinkedCopyEdited
    }

    func deploy(_ bundle: CustomInstrumentBundle, as item: StoreItem) throws {
        let folderURL = folderURL(for: item.id)
        var instrument = try Engine.validatedCustomInstrumentBundle(bundle)
        instrument.def.normalize()
        let previous = try? InstrumentFolder(folderURL: folderURL)
        let manifestURL = folderURL.appendingPathComponent(InstrumentFolder.manifestFileName)
        if previous == nil, FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
        let previousPaths = try previous?.sourcePaths() ?? []
        try InstrumentFolder.stampPackage(name: item.slug, version: item.version, in: folderURL)
        try InstrumentFolder.write(instrument, to: folderURL, replacing: previousPaths)
        let installation = StoreInstallation(
            itemID: item.id,
            version: item.version,
            snapshot: try snapshot(of: folderURL),
            hostCodeDigest: HostCode(files: instrument.files)?.digest
        )
        record(installation, forItemID: item.id)
        library.reload()
    }

    func remember(_ item: StoreItem) {
        guard installations[item.id] != nil else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = newestKnown(item)
        } else {
            items.append(item)
        }
    }

    func remove(itemID: StoreItem.ID) throws {
        let folderURL = folderURL(for: itemID)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }
        record(nil, forItemID: itemID)
        items.removeAll { $0.id == itemID }
        library.reload()
    }

    private func newestKnown(_ item: StoreItem) -> StoreItem {
        guard let known = items.first(where: { $0.id == item.id }), known.version > item.version else { return item }
        return known
    }

    private func latest(of installation: StoreInstallation) -> Storefront.LinkedInstallation.Latest {
        guard let item = items.first(where: { $0.id == installation.itemID }) else { return .unknown }
        return item.version > installation.version && LumaVersion.meets(item.minAppVersion) ? .newer(item) : .installed(item)
    }

    private func isEdited(_ folderURL: URL, since installed: InstrumentFolderLink.Snapshot) -> Bool {
        if let current = try? snapshot(of: folderURL) {
            return current != installed
        }
        return sourceDigests(in: folderURL) != installed.files
    }

    private func sourceDigests(in folderURL: URL) -> [String: String] {
        let generated: Set<String> = [InstrumentFolder.manifestFileName, InstrumentFolder.typingsFileName]
        let root = folderURL.standardizedFileURL.path + "/"
        var digests: [String: String] = [:]
        for case let fileURL as URL in FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey])!
        where (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = String(fileURL.standardizedFileURL.path.dropFirst(root.count))
            guard !generated.contains(path), let content = FileManager.default.contents(atPath: fileURL.path) else { continue }
            digests[path] = InstrumentFolderLink.Snapshot.digest(content)
        }
        return digests
    }

    private func snapshot(of folderURL: URL) throws -> InstrumentFolderLink.Snapshot {
        let folder = try InstrumentFolder(folderURL: folderURL)
        return InstrumentFolderLink.Snapshot(of: try folder.customInstrument(id: UUID(), createdAt: .distantPast, updatedAt: .distantPast))
    }

    private func record(_ installation: StoreInstallation?, forItemID itemID: StoreItem.ID) {
        LumaAppState.shared.setStoreInstallation(installation, forItemID: itemID)
        installations[itemID] = installation
    }
}
