import Foundation
import Observation

@Observable
@MainActor
public final class CustomInstrumentLibrary {
    public private(set) var defs: [CustomInstrumentDef] = []
    public private(set) var filesByDef: [UUID: [CustomInstrumentFile]] = [:]

    @ObservationIgnored public var observers: [@MainActor () -> Void] = []
    @ObservationIgnored private var defsObservation: StoreObservation?
    @ObservationIgnored private var filesObservation: StoreObservation?

    public init() {}

    public func start(store: ProjectStore) {
        defs = (try? store.fetchCustomInstrumentDefs()) ?? []
        filesByDef = Dictionary(
            grouping: (try? store.fetchAllCustomInstrumentFiles()) ?? [],
            by: \.defID
        )
        defsObservation = store.observeCustomInstrumentDefs { [weak self] defs in
            Task { @MainActor in
                self?.applyDefsChange(defs)
            }
        }
        filesObservation = store.observeCustomInstrumentFiles { [weak self] grouped in
            Task { @MainActor in
                self?.applyFilesChange(grouped)
            }
        }
    }

    public func def(withId id: UUID) -> CustomInstrumentDef? {
        defs.first { $0.id == id }
    }

    public func files(forDefID id: UUID) -> [CustomInstrumentFile] {
        filesByDef[id] ?? []
    }

    public func file(defID: UUID, path: String) -> CustomInstrumentFile? {
        filesByDef[defID]?.first { $0.path == path }
    }

    public func bundle(forDefID id: UUID) -> CustomInstrumentBundle? {
        guard let def = def(withId: id) else { return nil }
        return CustomInstrumentBundle(def: def, files: files(forDefID: id))
    }

    public func descriptors() -> [InstrumentDescriptor] {
        defs.map(descriptor(for:))
    }

    public func descriptor(for def: CustomInstrumentDef) -> InstrumentDescriptor {
        let defID = def.id
        let initialSettings = initialSettingStates(for: def)
        return InstrumentDescriptor(
            id: "custom:\(defID.uuidString)",
            kind: .custom,
            sourceIdentifier: defID.uuidString,
            displayName: def.name,
            icon: def.icon,
            compatibility: def.compatibility,
            makeInitialConfigJSON: {
                CustomInstrumentConfig(defID: defID, settings: initialSettings).encode()
            }
        )
    }

    public static func initialSettingStates(for def: CustomInstrumentDef) -> [String: SettingState] {
        Dictionary(uniqueKeysWithValues: def.settings.map {
            ($0.id, SettingState(enabled: $0.enabledByDefault, value: $0.schema.defaultValue))
        })
    }

    private func initialSettingStates(for def: CustomInstrumentDef) -> [String: SettingState] {
        Self.initialSettingStates(for: def)
    }

    private func applyDefsChange(_ defs: [CustomInstrumentDef]) {
        self.defs = defs
        notifyObservers()
    }

    private func applyFilesChange(_ filesByDef: [UUID: [CustomInstrumentFile]]) {
        self.filesByDef = filesByDef
        notifyObservers()
    }

    private func notifyObservers() {
        for observer in observers { observer() }
    }
}
