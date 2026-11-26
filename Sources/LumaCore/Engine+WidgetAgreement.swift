import Foundation

extension Engine {
    func adoptWidgetStates(of sessionID: UUID, from lab: [WidgetStateSnapshot]) {
        var adopted: [InstrumentViews.Key: WidgetState] = [:]
        for instance in instrumentsBySession[sessionID] ?? [] {
            for slot in widgetSlots(of: instance.id) {
                adopted[InstrumentViews.Key(instanceID: instance.id, widget: slot)] = WidgetState()
            }
        }
        for snapshot in lab {
            adopted[InstrumentViews.Key(instanceID: snapshot.instanceID, widget: snapshot.widget)] = snapshot.state
        }
        for (key, state) in adopted {
            widgetStates[key.instanceID, default: [:]][key.widget] = state
            consoleEntriesDropped[key] = 0
            _widgetUpdates.yield(WidgetUpdate(instanceID: key.instanceID, widget: key.widget, kind: .snapshot(state), revision: state.revision))
        }
    }

    func republishWidgetStates(of sessionID: UUID, over lab: [WidgetStateSnapshot]) {
        let labRevisions = Dictionary(
            lab.map { (InstrumentViews.Key(instanceID: $0.instanceID, widget: $0.widget), $0.state.revision) }, uniquingKeysWith: max)
        for instance in instrumentsBySession[sessionID] ?? [] {
            let held = labRevisions.keys.filter { $0.instanceID == instance.id }.map(\.widget)
            for slot in Set(widgetSlots(of: instance.id)).union(held) where hasChild(of: slot, in: instance.id) {
                let key = InstrumentViews.Key(instanceID: instance.id, widget: slot)
                restartWidgetState(slot, of: instance.id, as: widgetState(instanceID: instance.id, widget: slot), above: labRevisions[key] ?? 0)
            }
        }
    }

    func republishWidgetStates(ofInstance instanceID: UUID, in sessionID: UUID) {
        guard isHostingNode(sessionID) else { return }
        for child in children(of: instanceID) {
            publishChild(child, of: instanceID)
        }
        for slot in widgetSlots(of: instanceID) where hasChild(of: slot, in: instanceID) {
            restartWidgetState(slot, of: instanceID, as: widgetState(instanceID: instanceID, widget: slot), above: 0)
        }
    }

    func restartWidgetStates(of instanceID: UUID, declared: [String], restored: [String: WidgetState]) {
        for slot in Set(widgetSlots(of: instanceID)).union(declared).union(restored.keys) {
            restartWidgetState(slot, of: instanceID, as: restored[slot] ?? WidgetState(), above: 0)
        }
    }

    func resendStaleWidgetState(sessionID: UUID, instanceID: UUID, slot: String, labRevision: Int) {
        guard isHostingNode(sessionID), let instance = instrumentsBySession[sessionID]?.first(where: { $0.id == instanceID }) else { return }
        emitEngineWarning(
            subsystem: "collaboration",
            text: "The lab held a newer state of “\(descriptor(for: instance).displayName)” (\(WidgetSlot.split(slot).widget)) than this Luma sent; "
                + "sending this Luma's state again.")
        restartWidgetState(slot, of: instanceID, as: widgetState(instanceID: instanceID, widget: slot), above: labRevision)
    }

    func noteRows(of key: InstrumentViews.Key, changedBy update: WidgetUpdate) {
        switch update.kind {
        case .tableUpsert(let row):
            beginRow(row.id, of: key, at: update.revision)
        case .listUpsert(let item):
            beginRow(item.id, of: key, at: update.revision)
        case .tableRemove(let id), .listRemove(let id):
            rowsBegun[key]?[id] = nil
        case .clear:
            rowsBegun[key] = [:]
        case .snapshot(let state):
            rowsBegun[key] = Self.rows(of: state, beginningAt: update.revision)
        default:
            break
        }
    }

    func refusal(
        ofRemoteAction action: String, on slot: String, item: String?, instanceID: UUID, sessionID: UUID, seenRevision: Int
    ) -> String? {
        guard let instance = instrumentsBySession[sessionID]?.first(where: { $0.id == instanceID }) else {
            return "the host does not have this instrument"
        }
        let name = descriptor(for: instance).displayName
        if instrumentViews.approvalWanted(byInstance: instanceID) != nil {
            return "“\(name)” is waiting for its host to allow its code to run"
        }
        guard canReachAgent(of: instance) else { return "“\(name)” is not running at the host" }
        guard let item else {
            return agentState(of: instance).isEnabled(action, of: slot) ? nil : "this action is turned off at the host"
        }
        let state = widgetState(instanceID: instanceID, widget: slot)
        let present = state.tableRows.contains { $0.id == item } || state.listItems.contains { $0.id == item }
        guard present, let began = rowsBegun[InstrumentViews.Key(instanceID: instanceID, widget: slot)]?[item], began <= seenRevision else {
            return "this \(isList(slot, of: instanceID) ? "list" : "table") changed; try again"
        }
        return nil
    }

    func reportOutcome(of actionID: UUID, to recipient: FileRecipient?, offersFile: Bool, error: String?) {
        guard case .member(let sessionID) = recipient else { return }
        collaboration.sendOutcome(sessionID: sessionID, actionID: actionID, offersFile: offersFile, error: error)
    }

    func reportFailedAction(_ failure: WidgetActionFailure) {
        let sent = failure.action
        let instance = instrumentsBySession[sent.sessionID]?.first { $0.id == sent.instanceID }
        let name = instance.map { descriptor(for: $0).displayName } ?? "An instrument"
        let widget = widget(forInstanceID: sent.instanceID, widgetID: sent.widget)
        let actions = sent.item == nil ? widget?.actions : widget?.kind.rowActions
        let actionName = actions?.first { $0.id == sent.action }?.name ?? sent.action
        let host = sessions.first { $0.id == sent.sessionID }?.host?.name ?? "the host"
        let row = sent.item.map { " on row \($0)" } ?? ""
        emitEngineError(subsystem: "instruments", text: "“\(name)”: \(actionName)\(row) did not run at \(host)'s Luma: \(failure.reason).")
    }

    private func restartWidgetState(_ slot: String, of instanceID: UUID, as restored: WidgetState, above labRevision: Int) {
        let key = InstrumentViews.Key(instanceID: instanceID, widget: slot)
        guard let sessionID = sessionID(ofInstance: instanceID), isHostingNode(sessionID) else {
            widgetStates[instanceID, default: [:]][slot] = restored
            _widgetUpdates.yield(WidgetUpdate(instanceID: instanceID, widget: slot, kind: .snapshot(restored), revision: restored.revision))
            return
        }
        var state = restored
        state.revision = max(widgetState(instanceID: instanceID, widget: slot).revision, restored.revision, labRevision) + 1
        state.view?.revision = state.revision
        widgetStates[instanceID, default: [:]][slot] = state
        consoleEntriesDropped[key] = 0
        rowsBegun[key] = Self.rows(of: state, beginningAt: state.revision)
        _widgetUpdates.yield(WidgetUpdate(instanceID: instanceID, widget: slot, kind: .snapshot(state), revision: state.revision))
        guard localUserHosts(sessionID), let collabSID = collabSessionID(forSessionID: sessionID) else { return }
        publish(state, of: instanceID, widget: slot, sessionID: collabSID)
    }

    private func hasChild(of slot: String, in instanceID: UUID) -> Bool {
        guard let ref = WidgetSlot.split(slot).child else { return true }
        return children(of: instanceID).contains { $0.ref == ref }
    }

    private func beginRow(_ id: String, of key: InstrumentViews.Key, at revision: Int) {
        guard rowsBegun[key]?[id] == nil else { return }
        rowsBegun[key, default: [:]][id] = revision
    }

    private func isList(_ slot: String, of instanceID: UUID) -> Bool {
        guard case .list = widget(forInstanceID: instanceID, widgetID: slot)?.kind else { return false }
        return true
    }

    private static func rows(of state: WidgetState, beginningAt revision: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (state.tableRows.map(\.id) + state.listItems.map(\.id)).map { ($0, revision) })
    }
}
