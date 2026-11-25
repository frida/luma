import Foundation

extension Engine {
    public func children(of instanceID: UUID) -> [InstrumentChild] {
        instrumentChildren[instanceID] ?? []
    }

    public func childTemplate(_ template: String, of instance: InstrumentInstance) -> InstrumentChildTemplate? {
        customDef(of: instance.id)?.children.first { $0.id == template }
    }

    public func consumeChildSelectionRequest() {
        childSelectionRequest = nil
    }

    func restoreChildren(of instanceID: UUID, def: CustomInstrumentDef) -> [InstrumentChild] {
        let persisting = Set(def.children.filter(\.persists).map(\.id))
        let kept = ((try? store.fetchInstrumentChildren(instanceID: instanceID)) ?? []).filter { persisting.contains($0.ref.template) }
        let keptRefs = Set(kept.map(\.ref))
        for child in children(of: instanceID) where !keptRefs.contains(child.ref) {
            forgetChildState(child.ref, of: instanceID)
            publishChildRemoval(child.ref, of: instanceID)
        }
        instrumentChildren[instanceID] = kept
        for child in kept {
            publishChild(child, of: instanceID)
        }
        return kept
    }

    func handleChildTraffic(_ traffic: ChildTraffic) {
        switch traffic {
        case .upsert(let instanceID, let ref, let title, let subtitle, let badge):
            upsertChild(ref, of: instanceID, title: title, subtitle: subtitle, badge: badge)
        case .remove(let instanceID, let ref):
            removeChild(ref, of: instanceID)
        }
    }

    private func upsertChild(_ ref: ChildRef, of instanceID: UUID, title: String, subtitle: String?, badge: ChildBadge?) {
        var list = children(of: instanceID)
        let index = list.firstIndex { $0.ref == ref }
        let position = index.map { list[$0].position } ?? ((list.map(\.position).max() ?? -1) + 1)
        let child = InstrumentChild(ref: ref, position: position, title: title, subtitle: subtitle, badge: badge)
        if let index {
            list[index] = child
        } else {
            list.append(child)
        }
        instrumentChildren[instanceID] = list
        if customDef(of: instanceID)?.children.first(where: { $0.id == ref.template })?.persists == true {
            try? store.saveInstrumentChild(child, instanceID: instanceID)
        }
        publishChild(child, of: instanceID)
    }

    private func removeChild(_ ref: ChildRef, of instanceID: UUID) {
        guard children(of: instanceID).contains(where: { $0.ref == ref }) else { return }
        forgetChild(ref, of: instanceID)
        try? store.deleteInstrumentChild(ref, instanceID: instanceID)
        publishChildRemoval(ref, of: instanceID)
    }

    func dropTransientChildren(of instanceID: UUID) {
        let persisting = Set((customDef(of: instanceID)?.children ?? []).filter(\.persists).map(\.id))
        for child in children(of: instanceID) where !persisting.contains(child.ref.template) {
            forgetChild(child.ref, of: instanceID)
            publishChildRemoval(child.ref, of: instanceID)
        }
    }

    private func forgetChild(_ ref: ChildRef, of instanceID: UUID) {
        instrumentChildren[instanceID]?.removeAll { $0.ref == ref }
        forgetChildState(ref, of: instanceID)
        if childSelectionRequest?.instanceID == instanceID, childSelectionRequest?.child == ref {
            childSelectionRequest = nil
        }
    }

    private func forgetChildState(_ ref: ChildRef, of instanceID: UUID) {
        let prefix = WidgetSlot.prefix(of: ref)
        for slot in widgetSlots(of: instanceID) where slot.hasPrefix(prefix) {
            forgetWidgetState(slot, of: instanceID)
        }
    }

    private func publishChild(_ child: InstrumentChild, of instanceID: UUID) {
        guard let sessionID = sessionID(ofInstance: instanceID), localUserHosts(sessionID),
            let collabSID = collabSessionID(forSessionID: sessionID)
        else { return }
        collaboration.sendChild(child, sessionID: collabSID, instanceID: instanceID)
    }

    private func publishChildRemoval(_ ref: ChildRef, of instanceID: UUID) {
        guard let sessionID = sessionID(ofInstance: instanceID), localUserHosts(sessionID),
            let collabSID = collabSessionID(forSessionID: sessionID)
        else { return }
        collaboration.sendChildRemoval(ref, sessionID: collabSID, instanceID: instanceID)
    }

    func receiveRemoteChild(_ child: InstrumentChild, instanceID: UUID) {
        var list = children(of: instanceID)
        if let index = list.firstIndex(where: { $0.ref == child.ref }) {
            list[index] = child
        } else {
            list.append(child)
            list.sort { $0.position < $1.position }
        }
        instrumentChildren[instanceID] = list
    }

    func receiveRemoteChildRemoval(_ ref: ChildRef, instanceID: UUID) {
        forgetChild(ref, of: instanceID)
    }

    func adoptRemoteChildren(_ snapshot: [UUID: [InstrumentChild]], sessionIDs: Set<UUID>) {
        for instance in sessionIDs.flatMap({ instrumentsBySession[$0] ?? [] }) {
            let adopted = (snapshot[instance.id] ?? []).sorted { $0.position < $1.position }
            let adoptedRefs = Set(adopted.map(\.ref))
            for child in children(of: instance.id) where !adoptedRefs.contains(child.ref) {
                forgetChild(child.ref, of: instance.id)
            }
            instrumentChildren[instance.id] = adopted
        }
    }

    func republishChildren(over snapshot: [UUID: [InstrumentChild]], sessionIDs: Set<UUID>) {
        for instance in sessionIDs.flatMap({ instrumentsBySession[$0] ?? [] }) {
            let local = children(of: instance.id)
            for child in local {
                publishChild(child, of: instance.id)
            }
            let localRefs = Set(local.map(\.ref))
            for child in snapshot[instance.id] ?? [] where !localRefs.contains(child.ref) {
                publishChildRemoval(child.ref, of: instance.id)
            }
        }
    }

    func show(_ request: ShowRequest?, toChooserOf actionID: UUID, recipient: FileRecipient?, instance: InstrumentInstance) {
        guard let request, let recipient else { return }
        switch recipient {
        case .person:
            childSelectionRequest = ChildSelectionRequest(sessionID: instance.sessionID, instanceID: instance.id, child: request.child)
        case .member(let memberSessionID):
            collaboration.sendShow(request.child, sessionID: memberSessionID, actionID: actionID)
        }
    }

    func receiveShow(_ child: ChildRef?, sessionID: UUID, instanceID: UUID) {
        childSelectionRequest = ChildSelectionRequest(sessionID: sessionID, instanceID: instanceID, child: child)
    }

    private func customDef(of instanceID: UUID) -> CustomInstrumentDef? {
        guard let instance = instrumentsBySession.values.flatMap({ $0 }).first(where: { $0.id == instanceID }), instance.kind == .custom,
            let defID = UUID(uuidString: instance.sourceIdentifier)
        else { return nil }
        return customInstruments.def(withId: defID)
    }

    private func sessionID(ofInstance instanceID: UUID) -> UUID? {
        instrumentsBySession.first { $0.value.contains { $0.id == instanceID } }?.key
    }
}

struct ShowRequest: Sendable {
    let child: ChildRef?
}

enum ChildTraffic: Sendable {
    case upsert(instanceID: UUID, ref: ChildRef, title: String, subtitle: String?, badge: ChildBadge?)
    case remove(instanceID: UUID, ref: ChildRef)
}
