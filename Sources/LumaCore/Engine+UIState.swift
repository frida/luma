import Foundation

extension Engine {
    public func setEventStreamCollapsed(_ collapsed: Bool) {
        guard projectUIState.isEventStreamCollapsed != collapsed else { return }
        Task { @MainActor [weak self] in
            guard let self, self.projectUIState.isEventStreamCollapsed != collapsed else { return }
            self.projectUIState.isEventStreamCollapsed = collapsed
            try? self.store.save(self.projectUIState)
        }
    }

    public func setEventStreamBottomHeight(_ height: Double) {
        guard projectUIState.eventStreamBottomHeight != height else { return }
        Task { @MainActor [weak self] in
            guard let self, self.projectUIState.eventStreamBottomHeight != height else { return }
            self.projectUIState.eventStreamBottomHeight = height
            try? self.store.save(self.projectUIState)
        }
    }

    public func setCollaborationPanelVisible(_ visible: Bool) {
        guard projectUIState.isCollaborationPanelVisible != visible else { return }
        Task { @MainActor [weak self] in
            guard let self, self.projectUIState.isCollaborationPanelVisible != visible else { return }
            self.projectUIState.isCollaborationPanelVisible = visible
            try? self.store.save(self.projectUIState)
        }
    }

    public func setSelectedItemJSON(_ json: String?) {
        guard projectUIState.selectedItemJSON != json else { return }
        Task { @MainActor [weak self] in
            guard let self, self.projectUIState.selectedItemJSON != json else { return }
            self.projectUIState.selectedItemJSON = json
            try? self.store.save(self.projectUIState)
        }
    }

    public func setSidebarExpansion(sessionID: UUID, _ expansion: SidebarExpansion) {
        mutateSessionUIState(sessionID: sessionID) { $0.sidebarExpansion = expansion }
    }

    public func setSidebarExpansion(customInstrumentDefID: UUID, _ expansion: SidebarExpansion) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var state = self.customInstrumentDefUIStates[customInstrumentDefID]
                ?? CustomInstrumentDefUIState(defID: customInstrumentDefID)
            guard state.sidebarExpansion != expansion else { return }
            state.sidebarExpansion = expansion
            self.customInstrumentDefUIStates[customInstrumentDefID] = state
            try? self.store.save(state)
        }
    }

    public func setSessionDetailSection(sessionID: UUID, section: String?) {
        mutateSessionUIState(sessionID: sessionID) { $0.detailSection = section }
    }

    public func setLastSelectedModuleID(sessionID: UUID, moduleID: String?) {
        mutateSessionUIState(sessionID: sessionID) { $0.lastSelectedModuleID = moduleID }
    }

    public func setLastSelectedThreadID(sessionID: UUID, threadID: UInt?) {
        mutateSessionUIState(sessionID: sessionID) { $0.lastSelectedThreadID = threadID }
    }

    private func mutateSessionUIState(sessionID: UUID, _ mutate: (inout SessionUIState) -> Void) {
        var state = sessionUIStates[sessionID] ?? SessionUIState(sessionID: sessionID)
        mutate(&state)
        guard state != sessionUIStates[sessionID] else { return }
        sessionUIStates[sessionID] = state

        let saved = state
        Task { @MainActor [weak self] in
            try? self?.store.save(saved)
        }
    }

    public func sidebarExpansion(forSessionID sessionID: UUID) -> SidebarExpansion {
        sessionUIStates[sessionID]?.sidebarExpansion ?? .expanded
    }

    public func sidebarExpansion(forCustomInstrumentDefID defID: UUID) -> SidebarExpansion {
        customInstrumentDefUIStates[defID]?.sidebarExpansion ?? .expanded
    }

    public func sessionDetailSectionRaw(forSessionID sessionID: UUID) -> String? {
        sessionUIStates[sessionID]?.detailSection
    }

    public func lastSelectedModuleID(forSessionID sessionID: UUID) -> String? {
        sessionUIStates[sessionID]?.lastSelectedModuleID
    }

    public func lastSelectedThreadID(forSessionID sessionID: UUID) -> UInt? {
        sessionUIStates[sessionID]?.lastSelectedThreadID
    }
}
