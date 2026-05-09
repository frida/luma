import LumaCore
import SwiftUI

struct MissionTranscriptView: View {
    let turns: [MissionTurn]
    let actions: [MissionAction]
    let liveText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        TurnCard(turn: turn, actions: actionsForTurn(turn.id))
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
                if !liveText.isEmpty { withAnimation { proxy.scrollTo("live", anchor: .bottom) } }
            }
        }
    }

    private func actionsForTurn(_ turnID: UUID) -> [MissionAction] {
        actions.filter { $0.turnID == turnID }
    }
}

private struct TurnCard: View {
    let turn: MissionTurn
    let actions: [MissionAction]

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

    private var roleLabel: String {
        switch turn.role {
        case .assistant: return "Assistant"
        case .user: return "Tool results"
        case .tool: return "Tool"
        }
    }

    private var roleIcon: String {
        switch turn.role {
        case .assistant: return "sparkles"
        case .user: return "wrench.and.screwdriver"
        case .tool: return "terminal"
        }
    }

    private var roleColor: Color {
        switch turn.role {
        case .assistant: return .blue
        case .user: return .gray
        case .tool: return .orange
        }
    }

    private var parsedBlocks: [LLMContentBlock] {
        guard let data = turn.contentJSON.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LLMContentBlock].self, from: data)) ?? []
    }
}

private struct BlockView: View {
    let block: LLMContentBlock
    let actions: [MissionAction]

    var body: some View {
        switch block.content {
        case .text(let text):
            Text(renderMarkdown(text)).textSelection(.enabled)
        case .thinking(let text, _):
            DisclosureGroup("Thinking") {
                Text(renderMarkdown(text)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .redactedThinking:
            Text("[redacted thinking]").italic().foregroundStyle(.secondary)
        case .toolUse(let id, let name, let inputJSON):
            ToolUseBlock(id: id, name: name, inputJSON: inputJSON, action: actions.first(where: { $0.toolCallID == id }))
        case .toolResult(let id, let content, let isError):
            ToolResultBlock(toolUseID: id, content: content, isError: isError)
        }
    }
}

private struct ToolUseBlock: View {
    let id: String
    let name: String
    let inputJSON: String
    let action: MissionAction?

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
                Text(prettyJSON(inputJSON))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "ellipsis.circle.fill").foregroundStyle(.blue)
                Text("Streaming…").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
            }
            Text(renderMarkdown(text)).textSelection(.enabled)
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

private func renderMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    if let attributed = try? AttributedString(markdown: text, options: options) {
        return attributed
    }
    return AttributedString(text)
}

private func prettyJSON(_ s: String) -> String {
    guard let data = s.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
        let str = String(data: pretty, encoding: .utf8)
    else { return s }
    return str
}
