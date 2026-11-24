import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct InstrumentViewTarget {
    let instance: InstrumentInstance
    let def: CustomInstrumentDef
    let config: InstrumentWidget.ViewConfig
    let widgetName: String
    let hostCode: HostCode?
}

extension Engine {
    func viewTarget(for key: InstrumentViews.Key) -> InstrumentViewTarget? {
        guard let instance = instance(withID: key.instanceID),
            instance.kind == .custom,
            let defID = UUID(uuidString: instance.sourceIdentifier),
            let def = try? store.fetchCustomInstrumentDef(id: defID),
            let widget = def.widgets.first(where: { $0.id == key.widget }),
            case .view(let config) = widget.kind,
            let files = try? store.fetchCustomInstrumentFiles(defID: defID)
        else { return nil }
        return InstrumentViewTarget(instance: instance, def: def, config: config, widgetName: widget.label, hostCode: HostCode(files: files))
    }

    func isViewWidget(_ key: InstrumentViews.Key) -> Bool {
        guard let instance = instance(withID: key.instanceID),
            let defID = UUID(uuidString: instance.sourceIdentifier),
            let widget = customInstruments.def(withId: defID)?.widgets.first(where: { $0.id == key.widget })
        else { return false }
        return widget.kind.isView
    }

    func canSendViewMessage(from key: InstrumentViews.Key) -> Bool {
        guard let instance = instance(withID: key.instanceID) else { return false }
        return canSendViewMessage(from: instance)
    }

    func sendViewMessage(_ payload: WidgetViewPayload, from key: InstrumentViews.Key) -> Bool {
        guard let instance = instance(withID: key.instanceID), canSendViewMessage(from: instance) else { return false }
        if let node = node(forSessionID: instance.sessionID) {
            node.postViewMessage(instanceID: instance.id, widget: key.widget, payload: payload, from: nil)
        } else {
            collaboration.sendViewMessage(payload, sessionID: instance.sessionID, instanceID: instance.id, widget: key.widget)
        }
        return true
    }

    func deliverViewMessage(
        _ payload: WidgetViewPayload,
        sessionID: UUID,
        instanceID: UUID,
        widget: String,
        from sender: CollaborationSession.UserInfo
    ) {
        guard let node = node(forSessionID: sessionID),
            node.instruments.first(where: { $0.id == instanceID })?.attachment == .attached
        else { return }
        node.postViewMessage(instanceID: instanceID, widget: widget, payload: payload, from: sender)
    }

    func persistedWidgetStates(instanceID: UUID) -> [String: WidgetState] {
        var states = (try? store.fetchWidgetStates(instanceID: instanceID)) ?? [:]
        for (widget, state) in states where state.view != nil {
            let blob = Self.viewDataBlobID(instanceID: instanceID, widget: widget)
            states[widget]?.view?.payload.data = try? blobs.map(id: blob, kind: .viewState)
        }
        return states
    }

    func persistViewData(of view: WidgetViewState?, instanceID: UUID, widget: String) {
        let blob = Self.viewDataBlobID(instanceID: instanceID, widget: widget)
        if let data = view?.payload.data {
            blobs.write(data, id: blob, kind: .viewState)
        } else {
            blobs.delete(id: blob, kind: .viewState)
        }
    }

    func forgetViewData(of instance: InstrumentInstance) {
        guard let defID = UUID(uuidString: instance.sourceIdentifier), let def = customInstruments.def(withId: defID) else { return }
        for widget in def.widgets where widget.kind.isView {
            blobs.delete(id: Self.viewDataBlobID(instanceID: instance.id, widget: widget.id), kind: .viewState)
        }
    }

    private func instance(withID instanceID: UUID) -> InstrumentInstance? {
        instrumentsBySession.values.lazy.flatMap { $0 }.first { $0.id == instanceID }
    }

    private func canSendViewMessage(from instance: InstrumentInstance) -> Bool {
        canReachAgent(of: instance)
    }

    private static func viewDataBlobID(instanceID: UUID, widget: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(instanceID.uuidString)/\(widget)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

extension WidgetUpdate.Kind {
    var isTransient: Bool {
        switch self {
        case .viewEvent, .viewRefused:
            return true
        default:
            return false
        }
    }
}

extension WidgetUpdate {
    func supersedes(_ state: WidgetState) -> Bool {
        switch kind {
        case .viewEvent, .viewRefused:
            return true
        case .viewState(let view):
            return revision > state.revision || (revision == state.revision && state.view?.revision != view.revision)
        default:
            return revision > state.revision
        }
    }
}
