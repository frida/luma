import Foundation

@MainActor
public final class MissionExecutor {
    public typealias SystemPromptBuilder = @MainActor (Mission) -> String
    public typealias LiveDeltaSink = @MainActor (UUID, LLMTurnEvent) -> Void

    private let store: ProjectStore
    private let registry: LLMProviderRegistry
    private let credentials: LLMCredentialStore
    public let catalog: ToolCatalog
    private let systemPromptBuilder: SystemPromptBuilder
    private weak var collaboration: CollaborationSession?
    public var liveDeltaSink: LiveDeltaSink?

    private var inFlight: [UUID: Task<Void, Never>] = [:]

    public init(
        store: ProjectStore,
        registry: LLMProviderRegistry,
        credentials: LLMCredentialStore,
        catalog: ToolCatalog,
        collaboration: CollaborationSession?,
        systemPromptBuilder: @escaping SystemPromptBuilder
    ) {
        self.store = store
        self.registry = registry
        self.credentials = credentials
        self.catalog = catalog
        self.collaboration = collaboration
        self.systemPromptBuilder = systemPromptBuilder
    }

    public func start(missionID: UUID) {
        guard inFlight[missionID] == nil else { return }
        runDetached(missionID: missionID, mode: .initial)
    }

    public func resume(missionID: UUID) {
        guard inFlight[missionID] == nil else { return }
        runDetached(missionID: missionID, mode: .resume)
    }

    public func cancel(missionID: UUID) {
        inFlight[missionID]?.cancel()
        inFlight[missionID] = nil
        if var mission = try? store.fetchMission(id: missionID), mission.status.isLive {
            mission.status = .cancelled
            persistMission(mission)
        }
    }

    public func runActionByID(_ actionID: UUID, mission: Mission) async {
        guard let action = try? store.fetchMissionAction(id: actionID) else { return }
        await runAction(action, mission: mission)
    }

    private enum LoopMode { case initial, resume }

    private func runDetached(missionID: UUID, mode: LoopMode) {
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.runLoop(missionID: missionID, mode: mode)
            self?.inFlight.removeValue(forKey: missionID)
        }
        inFlight[missionID] = task
    }

    private func runLoop(missionID: UUID, mode: LoopMode) async {
        guard var mission = try? store.fetchMission(id: missionID) else { return }
        guard let provider = registry.provider(id: mission.providerID) else {
            failMission(&mission, reason: "Provider not registered: \(mission.providerID)")
            return
        }
        let apiKey = (try? await credentials.apiKey(providerID: mission.providerID)) ?? nil
        if provider.descriptor.capabilities.supports(.apiKey), apiKey == nil {
            failMission(&mission, reason: "Missing API key for provider \(mission.providerID)")
            return
        }

        mission.status = .running
        persistMission(mission)

        if mode == .resume {
            do {
                try synthesizeUserTurnFromActions(mission: mission)
            } catch {
                failMission(&mission, reason: "Could not synthesize tool results: \(error.localizedDescription)")
                return
            }
        }

        while true {
            if Task.isCancelled {
                mission.status = .cancelled
                persistMission(mission)
                return
            }

            if isBudgetExhausted(mission) {
                mission.status = .paused
                persistMission(mission)
                return
            }

            do {
                try drainPendingUserMessage(mission: &mission)
            } catch {
                failMission(&mission, reason: "Could not enqueue user message: \(error.localizedDescription)")
                return
            }

            let request: LLMTurnRequest
            do {
                request = try buildRequest(for: mission)
            } catch {
                failMission(&mission, reason: "Could not build request: \(error.localizedDescription)")
                return
            }

            let outcome = await streamOneTurn(provider: provider, request: request, apiKey: apiKey, missionID: mission.id)

            if !outcome.blocks.isEmpty {
                do {
                    try persistAssistantTurn(mission: &mission, outcome: outcome)
                } catch {
                    failMission(&mission, reason: "Could not persist turn: \(error.localizedDescription)")
                    return
                }
            }

            if let error = outcome.error {
                if isCancellation(error) {
                    mission.status = .cancelled
                    persistMission(mission)
                    return
                }
                failMission(&mission, reason: error.localizedDescription)
                return
            }

            let toolUses = outcome.blocks.compactMap { block -> ToolCallSpec? in
                if case .toolUse(let id, let name, let inputJSON) = block.content {
                    return ToolCallSpec(id: id, name: name, inputJSON: inputJSON)
                }
                return nil
            }

            if toolUses.isEmpty || outcome.stopReason == .endTurn {
                mission.status = .completed
                persistMission(mission)
                return
            }

            let assistantTurnID = try? store.fetchMissionTurns(missionID: mission.id).last?.id
            let actions = createActions(missionID: mission.id, turnID: assistantTurnID, calls: toolUses)
            for action in actions {
                persistAction(action)
            }

            for action in actions where action.isObserve {
                await runAction(action, mission: mission)
            }

            let stillPending = (try? store.hasPendingMissionActions(missionID: mission.id)) ?? false
            if stillPending {
                mission.status = .awaitingApproval
                persistMission(mission)
                return
            }

            do {
                try synthesizeUserTurnFromActions(mission: mission)
            } catch {
                failMission(&mission, reason: "Could not synthesize tool results: \(error.localizedDescription)")
                return
            }
        }
    }

    private func runAction(_ action: MissionAction, mission: Mission) async {
        var running = action
        running.status = .running
        running.decidedAt = running.decidedAt ?? Date()
        persistAction(running)

        let argsObject: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(action.argsJSON.utf8))) as? [String: Any] ?? [:]
        let invocation = ActionInvocation(
            args: argsObject,
            mission: mission,
            sessionID: action.sessionID,
            toolCallID: action.toolCallID ?? action.id.uuidString
        )

        var completed = running
        do {
            let result = try await catalog.execute(action.toolName, invocation: invocation)
            completed.status = result.isError ? .failed : .succeeded
            completed.resultJSON = result.resultJSON
            completed.resultSummary = result.summary
            completed.resultAttachmentsJSON = encodeAttachments(result.attachments)
            if result.isError { completed.error = result.summary }
        } catch {
            completed.status = .failed
            completed.error = error.localizedDescription
            completed.resultJSON = #"{"error": "\#(error.localizedDescription)"}"#
            completed.resultSummary = error.localizedDescription
        }
        completed.completedAt = Date()
        persistAction(completed)
    }

    private func isBudgetExhausted(_ mission: Mission) -> Bool {
        mission.tokenBudgetInput > 0 && mission.tokensUsedInput >= mission.tokenBudgetInput
    }

    private func buildRequest(for mission: Mission) throws -> LLMTurnRequest {
        let systemText = systemPromptBuilder(mission)
        let systemBlocks: [LLMContentBlock] = [
            LLMContentBlock(content: .text(systemText), cacheBoundary: true),
        ]

        let messages = try reconstructMessages(mission: mission)

        let tools = catalog.toolSpecs()

        let maxOut = max(mission.tokenBudgetOutput - mission.tokensUsedOutput, 1024)

        return LLMTurnRequest(
            modelID: mission.modelID,
            systemBlocks: systemBlocks,
            messages: messages,
            tools: tools,
            maxOutputTokens: min(maxOut, 16_384),
            thinkingBudget: mission.thinkingBudget,
            reasoningEffort: mission.reasoningEffort,
            temperature: mission.temperature,
            mission: mission
        )
    }

    private func reconstructMessages(mission: Mission) throws -> [LLMMessage] {
        var messages: [LLMMessage] = [
            LLMMessage(role: .user, blocks: [.text(mission.goalText)]),
        ]
        let turns = try store.fetchMissionTurns(missionID: mission.id)
        for turn in turns {
            guard let role = LLMRole(rawValue: turn.role.rawValue) else { continue }
            guard let data = turn.contentJSON.data(using: .utf8) else { continue }
            guard let blocks = try? JSONDecoder.iso.decode([LLMContentBlock].self, from: data) else { continue }
            messages.append(LLMMessage(role: role, blocks: blocks))
        }
        return messages
    }

    private struct TurnOutcome {
        var blocks: [LLMContentBlock]
        var usage: LLMUsage
        var stopReason: LLMStopReason
        var modelID: String
        var error: Error?
    }

    private func streamOneTurn(
        provider: any LLMProvider,
        request: LLMTurnRequest,
        apiKey: String?,
        missionID: UUID
    ) async -> TurnOutcome {
        var blocks: [LLMContentBlock] = []
        var streamedText = ""
        var usage = LLMUsage.zero
        var stopReason = LLMStopReason.endTurn
        var capturedError: Error?

        let baseURL = LumaAppState.shared.providerBaseURL(providerID: provider.descriptor.id).flatMap(URL.init(string:))
        let stream = provider.streamTurn(request, apiKey: apiKey, baseURL: baseURL)
        do {
            for try await event in stream {
                liveDeltaSink?(missionID, event)
                switch event {
                case .textDelta(let text):
                    streamedText.append(text)
                case .usage(let u):
                    usage = u
                case .messageStop(let reason):
                    stopReason = reason
                case .finalMessage(_, let finalBlocks):
                    blocks = finalBlocks
                default:
                    break
                }
            }
        } catch {
            capturedError = error
            if isCancellation(error) {
                stopReason = .cancelled
            } else {
                stopReason = .error
            }
        }

        if blocks.isEmpty, !streamedText.isEmpty {
            blocks = [LLMContentBlock(content: .text(streamedText))]
        }

        return TurnOutcome(
            blocks: blocks,
            usage: usage,
            stopReason: stopReason,
            modelID: request.modelID,
            error: capturedError
        )
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case LLMProviderError.cancelled = error { return true }
        return false
    }

    private func persistAssistantTurn(mission: inout Mission, outcome: TurnOutcome) throws {
        let index = try store.nextMissionTurnIndex(missionID: mission.id)
        let json = try JSONEncoder.iso.encode(outcome.blocks)
        let turn = MissionTurn(
            missionID: mission.id,
            index: index,
            role: .assistant,
            contentJSON: String(data: json, encoding: .utf8) ?? "[]",
            modelID: outcome.modelID,
            stopReason: outcome.stopReason.rawValue,
            inputTokens: outcome.usage.inputTokens,
            outputTokens: outcome.usage.outputTokens,
            cacheReadTokens: outcome.usage.cacheReadTokens,
            cacheCreateTokens: outcome.usage.cacheCreateTokens
        )
        try persistTurn(turn)

        mission.tokensUsedInput += outcome.usage.inputTokens
        mission.tokensUsedOutput += outcome.usage.outputTokens
        mission.cacheReadTokens += outcome.usage.cacheReadTokens
        mission.cacheCreateTokens += outcome.usage.cacheCreateTokens
        try store.save(mission)
        collaboration?.enqueueMissionUpsert(mission)
    }

    private struct ToolCallSpec {
        let id: String
        let name: String
        let inputJSON: String
    }

    private func createActions(missionID: UUID, turnID: UUID?, calls: [ToolCallSpec]) -> [MissionAction] {
        calls.map { call in
            let isObserve = catalog.spec(named: call.name)?.isObserve ?? false
            return MissionAction(
                missionID: missionID,
                turnID: turnID,
                toolName: call.name,
                argsJSON: call.inputJSON,
                isObserve: isObserve,
                sessionID: nil,
                toolCallID: call.id
            )
        }
    }

    private func synthesizeUserTurnFromActions(mission: Mission) throws {
        let actions = try store.fetchMissionActions(missionID: mission.id)
        guard let lastTurnID = try store.fetchMissionTurns(missionID: mission.id).last?.id else { return }
        let resultsForTurn = actions.filter { $0.turnID == lastTurnID && $0.status != .pending && $0.status != .running }

        let blocks: [LLMContentBlock] = resultsForTurn.map { action in
            let content: String
            let isError: Bool
            switch action.status {
            case .rejected:
                content = action.rejectionReason.map { "User declined to run this tool: \($0)" } ?? "User declined to run this tool."
                isError = true
            case .failed:
                content = action.error ?? action.resultSummary ?? "Tool failed."
                isError = true
            case .succeeded:
                content = action.resultJSON ?? action.resultSummary ?? "(empty)"
                isError = false
            default:
                content = "(no result yet)"
                isError = true
            }
            let attachments: [LLMAttachment]
            if let json = action.resultAttachmentsJSON,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([LLMAttachment].self, from: data)
            {
                attachments = decoded
            } else {
                attachments = []
            }
            return LLMContentBlock(content: .toolResult(
                toolUseID: action.toolCallID ?? action.id.uuidString,
                contentJSON: content,
                isError: isError,
                attachments: attachments
            ))
        }

        let index = try store.nextMissionTurnIndex(missionID: mission.id)
        let json = try JSONEncoder.iso.encode(blocks)
        let turn = MissionTurn(
            missionID: mission.id,
            index: index,
            role: .user,
            contentJSON: String(data: json, encoding: .utf8) ?? "[]"
        )
        try persistTurn(turn)
    }

    private func drainPendingUserMessage(mission: inout Mission) throws {
        var drained = ""
        let saved = store.updateMission(id: mission.id) { m in
            drained = m.pendingUserText
            m.pendingUserText = ""
        }
        guard !drained.isEmpty else { return }
        if let saved {
            mission.pendingUserText = saved.pendingUserText
            collaboration?.enqueueMissionUpsert(saved)
        }

        let turns = try store.fetchMissionTurns(missionID: mission.id)
        if let last = turns.last, last.role == .user {
            try appendTextBlock(drained, to: last)
        } else {
            try persistFreshUserTurn(text: drained, missionID: mission.id)
        }
    }

    private func appendTextBlock(_ text: String, to turn: MissionTurn) throws {
        var blocks: [LLMContentBlock] = []
        if let data = turn.contentJSON.data(using: .utf8) {
            blocks = (try? JSONDecoder.iso.decode([LLMContentBlock].self, from: data)) ?? []
        }
        blocks.append(LLMContentBlock(content: .text(text)))
        let json = try JSONEncoder.iso.encode(blocks)

        var updated = turn
        updated.contentJSON = String(data: json, encoding: .utf8) ?? "[]"
        try persistTurn(updated)
    }

    private func persistFreshUserTurn(text: String, missionID: UUID) throws {
        let blocks = [LLMContentBlock(content: .text(text))]
        let json = try JSONEncoder.iso.encode(blocks)
        let index = try store.nextMissionTurnIndex(missionID: missionID)
        let turn = MissionTurn(
            missionID: missionID,
            index: index,
            role: .user,
            contentJSON: String(data: json, encoding: .utf8) ?? "[]"
        )
        try persistTurn(turn)
    }

    private func persistMission(_ mission: Mission) {
        let saved = store.updateMission(id: mission.id) { m in
            m.status = mission.status
            m.tokensUsedInput = mission.tokensUsedInput
            m.tokensUsedOutput = mission.tokensUsedOutput
            m.cacheReadTokens = mission.cacheReadTokens
            m.cacheCreateTokens = mission.cacheCreateTokens
            m.thinkingBudget = mission.thinkingBudget
            m.reasoningEffort = mission.reasoningEffort
        }
        if let saved {
            collaboration?.enqueueMissionUpsert(saved)
        }
    }

    private func persistTurn(_ turn: MissionTurn) throws {
        try store.save(turn)
        collaboration?.enqueueMissionTurn(turn)
    }

    private func persistAction(_ action: MissionAction) {
        try? store.save(action)
        collaboration?.enqueueMissionAction(action)
    }

    private func failMission(_ mission: inout Mission, reason: String) {
        mission.status = .failed
        persistMission(mission)
        let block = LLMContentBlock(content: .text("[mission failed] \(reason)"))
        if let json = try? JSONEncoder.iso.encode([block]),
            let str = String(data: json, encoding: .utf8),
            let index = try? store.nextMissionTurnIndex(missionID: mission.id)
        {
            let turn = MissionTurn(
                missionID: mission.id,
                index: index,
                role: .assistant,
                contentJSON: str,
                stopReason: "error"
            )
            try? store.save(turn)
            collaboration?.enqueueMissionTurn(turn)
        }
    }
}

private func encodeAttachments(_ attachments: [LLMAttachment]) -> String? {
    if attachments.isEmpty { return nil }
    guard let data = try? JSONEncoder().encode(attachments) else { return nil }
    return String(data: data, encoding: .utf8)
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
