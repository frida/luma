import LumaCore
import SwiftUI

struct MissionTranscriptView: View {
    let turns: [MissionTurn]
    let actions: [MissionAction]
    let liveText: String
    private let actionsByTurnID: [UUID: [MissionAction]]

    init(turns: [MissionTurn], actions: [MissionAction], liveText: String) {
        self.turns = turns
        self.actions = actions
        self.liveText = liveText
        actionsByTurnID = Dictionary(grouping: actions.compactMap { action -> (UUID, MissionAction)? in
            guard let turnID = action.turnID else { return nil }
            return (turnID, action)
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        TurnCard(turn: turn, actions: actionsByTurnID[turn.id] ?? [])
                            .equatable()
                            .id(turn.id)
                    }
                    if !liveText.isEmpty {
                        TurnLiveCard(text: liveText)
                            .id("live")
                    }
                }
                .padding()
            }
            .onChange(of: turns.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .onChange(of: liveText) { _, _ in
                if !liveText.isEmpty { proxy.scrollTo("live", anchor: .bottom) }
            }
        }
    }
}

private struct TurnCard: View, Equatable {
    let turn: MissionTurn
    let actions: [MissionAction]
    private let parsedBlocks: [LLMContentBlock]
    private let actionKeys: [ActionRenderKey]

    init(turn: MissionTurn, actions: [MissionAction]) {
        self.turn = turn
        self.actions = actions
        parsedBlocks = Self.decodeBlocks(from: turn)
        actionKeys = actions.map(ActionRenderKey.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: roleIcon)
                    .foregroundStyle(roleColor)
                Text(roleLabel).font(.caption.weight(.semibold)).foregroundStyle(roleColor)
                Spacer()
                if turn.outputTokens > 0 {
                    Text("\(turn.outputTokens) tok").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ForEach(parsedBlocks.indices, id: \.self) { i in
                BlockView(block: parsedBlocks[i], actions: actions)
            }
        }
        .padding()
        .background(roleColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func == (lhs: TurnCard, rhs: TurnCard) -> Bool {
        lhs.turn.id == rhs.turn.id
            && lhs.turn.role == rhs.turn.role
            && lhs.turn.contentJSON == rhs.turn.contentJSON
            && lhs.turn.outputTokens == rhs.turn.outputTokens
            && lhs.actionKeys == rhs.actionKeys
    }

    private var roleLabel: String {
        switch turn.role {
        case .assistant: return "Assistant"
        case .user: return userTurnIsToolResults ? "Tool results" : "You"
        case .tool: return "Tool"
        }
    }

    private var roleIcon: String {
        switch turn.role {
        case .assistant: return "sparkles"
        case .user: return userTurnIsToolResults ? "wrench.and.screwdriver" : "person.fill"
        case .tool: return "terminal"
        }
    }

    private var roleColor: Color {
        switch turn.role {
        case .assistant: return .blue
        case .user: return userTurnIsToolResults ? .gray : .purple
        case .tool: return .orange
        }
    }

    private var userTurnIsToolResults: Bool {
        for block in parsedBlocks {
            if case .text = block.content { return false }
        }
        return true
    }

    private static func decodeBlocks(from turn: MissionTurn) -> [LLMContentBlock] {
        guard let data = turn.contentJSON.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LLMContentBlock].self, from: data)) ?? []
    }
}

private struct ActionRenderKey: Equatable {
    let id: UUID
    let status: MissionActionStatus
    let isObserve: Bool
    let resultSummary: String?
    let toolCallID: String?

    init(_ action: MissionAction) {
        id = action.id
        status = action.status
        isObserve = action.isObserve
        resultSummary = action.resultSummary
        toolCallID = action.toolCallID
    }
}

private struct BlockView: View {
    let block: LLMContentBlock
    let actions: [MissionAction]

    var body: some View {
        switch block.content {
        case .text(let text):
            MarkdownView(text)
        case .thinking(let text, _):
            DisclosureGroup("Thinking") {
                MarkdownView(text).font(.callout).foregroundStyle(.secondary)
            }
        case .redactedThinking:
            Text("[redacted thinking]").italic().foregroundStyle(.secondary)
        case .toolUse(let id, let name, let inputJSON):
            ToolUseBlock(id: id, name: name, inputJSON: inputJSON, action: actions.first(where: { $0.toolCallID == id }))
        case .toolResult(let id, let content, let isError, _):
            ToolResultBlock(toolUseID: id, content: content, isError: isError)
        }
    }
}

private struct ToolUseBlock: View {
    let id: String
    let name: String
    let inputJSON: String
    let action: MissionAction?
    private let prettyInputJSON: String

    init(id: String, name: String, inputJSON: String, action: MissionAction?) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        self.action = action
        prettyInputJSON = prettyJSON(inputJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: action?.isObserve == true ? "eye" : "wrench.adjustable")
                    .foregroundStyle(.tint)
                Text(name).font(.callout.monospaced().weight(.semibold))
                if let action { ActionStatusPill(status: action.status) }
                Spacer()
            }
            if !inputJSON.isEmpty, inputJSON != "{}" {
                Text(prettyInputJSON)
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
            }
            if let summary = action?.resultSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct ToolResultBlock: View {
    let toolUseID: String
    let content: String
    let isError: Bool

    var body: some View {
        DisclosureGroup(isError ? "Tool result (error)" : "Tool result") {
            Text(content)
                .font(.caption.monospaced())
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TurnLiveCard: View {
    let text: String
    private let stableText: String

    init(text: String) {
        self.text = text
        stableText = MarkdownStreaming.stablePrefix(of: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "ellipsis.circle.fill").foregroundStyle(.blue)
                Text("Streaming…").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
            }
            MarkdownView(stableText)
        }
        .padding()
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ActionStatusPill: View {
    let status: MissionActionStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .pending: .orange
        case .approved: .blue
        case .rejected: .gray
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        }
    }
}

private func prettyJSON(_ s: String) -> String {
    guard let data = s.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
        let str = String(data: pretty, encoding: .utf8)
    else { return s }
    return str
}
