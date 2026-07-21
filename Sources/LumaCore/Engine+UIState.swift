import Foundation

extension Engine {
    public var pharoSnippets: [PharoPlaygroundSnippet] {
        guard let json = projectUIState.pharoSnippetsJSON,
            let data = json.data(using: .utf8),
            let snippets = try? JSONDecoder().decode([PharoPlaygroundSnippet].self, from: data)
        else { return [] }
        return snippets
    }

    public func setPharoSnippets(_ snippets: [PharoPlaygroundSnippet]) {
        let json = (try? JSONEncoder().encode(snippets)).flatMap { String(data: $0, encoding: .utf8) }
        guard projectUIState.pharoSnippetsJSON != json else { return }
        Task { @MainActor [weak self] in
            guard let self, self.projectUIState.pharoSnippetsJSON != json else { return }
            self.projectUIState.pharoSnippetsJSON = json
            try? self.store.save(self.projectUIState)
        }
    }

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

    public func setSidebarExpansion(sessionID: UUID, group: SessionSidebarGroup, _ expansion: SidebarExpansion) {
        mutateSessionUIState(sessionID: sessionID) { state in
            switch group {
            case .modules: state.modulesExpansion = expansion
            case .threads: state.threadsExpansion = expansion
            }
        }
    }

    public func setHooksExpansion(sessionID: UUID, instrumentID: UUID, _ expansion: SidebarExpansion) {
        mutateSessionUIState(sessionID: sessionID) { state in
            switch expansion {
            case .expanded: state.collapsedHookInstruments.remove(instrumentID)
            case .collapsed: state.collapsedHookInstruments.insert(instrumentID)
            }
        }
    }

    public func setLastSelectedModuleID(sessionID: UUID, moduleID: String?) {
        mutateSessionUIState(sessionID: sessionID) { $0.lastSelectedModuleID = moduleID }
    }

    public func setLastSelectedThreadID(sessionID: UUID, threadID: UInt?) {
        mutateSessionUIState(sessionID: sessionID) { $0.lastSelectedThreadID = threadID }
    }

    public func setREPLLanguage(sessionID: UUID, _ language: REPLLanguage) {
        mutateSessionUIState(sessionID: sessionID) { $0.replLanguage = language }
    }

    public func setREPLDraft(sessionID: UUID, _ draft: String?) {
        mutateSessionUIState(sessionID: sessionID) { $0.replDraft = draft }
    }

    public func setREPLSeekAnchor(sessionID: UUID, _ anchor: AddressAnchor?) {
        mutateSessionUIState(sessionID: sessionID) { $0.replSeekAnchor = anchor }
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

    public func sidebarExpansion(forSessionID sessionID: UUID, group: SessionSidebarGroup) -> SidebarExpansion {
        let state = sessionUIStates[sessionID]
        switch group {
        case .modules: return state?.modulesExpansion ?? .collapsed
        case .threads: return state?.threadsExpansion ?? .collapsed
        }
    }

    public func hooksExpansion(forSessionID sessionID: UUID, instrumentID: UUID) -> SidebarExpansion {
        let collapsed = sessionUIStates[sessionID]?.collapsedHookInstruments.contains(instrumentID) ?? false
        return collapsed ? .collapsed : .expanded
    }

    public func lastSelectedModuleID(forSessionID sessionID: UUID) -> String? {
        sessionUIStates[sessionID]?.lastSelectedModuleID
    }

    public func lastSelectedThreadID(forSessionID sessionID: UUID) -> UInt? {
        sessionUIStates[sessionID]?.lastSelectedThreadID
    }

    public func replLanguage(forSessionID sessionID: UUID) -> REPLLanguage {
        sessionUIStates[sessionID]?.replLanguage ?? .javascript
    }

    public func replDraft(forSessionID sessionID: UUID) -> String? {
        sessionUIStates[sessionID]?.replDraft
    }

    public func replSeekAnchor(forSessionID sessionID: UUID) -> AddressAnchor? {
        sessionUIStates[sessionID]?.replSeekAnchor
    }
}
