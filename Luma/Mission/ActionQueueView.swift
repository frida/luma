import LumaCore
import SwiftUI

struct ActionQueueView: View {
    let engine: Engine
    let actions: [MissionAction]

    @State private var rejectingAction: MissionAction?
    @State private var rejectReason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                Text("Action Queue")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(actions.count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding()

            if actions.isEmpty {
                Text("No actions awaiting approval.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(actions) { action in
                            if action.toolName == MissionTools.requestUserInputToolName {
                                RequestUserInputCard(action: action) { answer in
                                    engine.submitUserInputResponse(actionID: action.id, answer: answer)
                                }
                            } else {
                                ActionCard(
                                    engine: engine,
                                    action: action,
                                    onApprove: { Task { await engine.approveMissionAction(actionID: action.id) } },
                                    onReject: {
                                        rejectingAction = action
                                        rejectReason = ""
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Reject action?", isPresented: Binding(
            get: { rejectingAction != nil },
            set: { if !$0 { rejectingAction = nil } }
        )) {
            TextField("Reason (optional)", text: $rejectReason)
            Button("Reject", role: .destructive) {
                if let a = rejectingAction {
                    let reason = rejectReason.isEmpty ? nil : rejectReason
                    Task { await engine.rejectMissionAction(actionID: a.id, reason: reason) }
                }
                rejectingAction = nil
            }
            Button("Cancel", role: .cancel) { rejectingAction = nil }
        } message: {
            if let a = rejectingAction {
                Text("Tell the agent why you rejected \(a.toolName). This signal can help it adjust.")
            }
        }
    }
}

struct ActionCard: View {
    let engine: Engine
    let action: MissionAction
    var onApprove: () -> Void
    var onReject: () -> Void

    var body: some View {
        let parsed = parsedArgs(action.argsJSON)
        let codeView = codeArgView(toolName: action.toolName, args: parsed, engine: engine)
        let remainingJSON = jsonWithoutCodeField(toolName: action.toolName, args: parsed, engine: engine)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wrench.adjustable.fill").foregroundStyle(.tint)
                Text(action.toolName).font(.body.monospaced().weight(.semibold))
                Spacer()
                Text(action.requestedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }

            codeView

            if let remainingJSON {
                Text(remainingJSON)
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
            }

            if let rationale = action.rationale {
                Text(rationale).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            HStack {
                Button("Reject", role: .destructive, action: onReject)
                Spacer()
                Button("Approve", action: onApprove).buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@ViewBuilder
private func codeArgView(toolName: String, args: [String: Any], engine: Engine) -> some View {
    if let attachment = codeAttachment(toolName: toolName, args: args, engine: engine) {
        ReadOnlyCodeView(source: attachment.source, profile: attachment.profile, engine: engine)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct ReadOnlyCodeView: View {
    let source: String
    let profile: EditorProfile
    let engine: Engine

    @State private var text: String

    init(source: String, profile: EditorProfile, engine: Engine) {
        self.source = source
        var readOnlyProfile = profile
        readOnlyProfile.readOnly = true
        self.profile = readOnlyProfile
        self.engine = engine
        _text = State(initialValue: source)
    }

    var body: some View {
        CodeEditorView(text: $text, profile: profile, engine: engine)
            .onChange(of: source) { _, newValue in
                text = newValue
            }
    }
}

private struct CodeAttachment {
    let source: String
    let profile: EditorProfile
}

private func codeAttachment(toolName: String, args: [String: Any], engine: Engine) -> CodeAttachment? {
    guard let preview = engine.missionTools.spec(named: toolName)?.codePreview,
        let source = args[preview.field] as? String
    else { return nil }
    return CodeAttachment(source: source, profile: editorProfile(for: preview.language))
}

private func editorProfile(for language: CodePreviewLanguage) -> EditorProfile {
    switch language {
    case .fridaJavaScript:
        return .fridaCodeShare()
    case .fridaTypeScript:
        return .fridaTracerHook(packages: [])
    }
}

private func jsonWithoutCodeField(toolName: String, args: [String: Any], engine: Engine) -> String? {
    var stripped = args
    if let field = engine.missionTools.spec(named: toolName)?.codePreview?.field {
        stripped.removeValue(forKey: field)
    }
    if stripped.isEmpty { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: stripped, options: [.prettyPrinted, .sortedKeys]),
        let str = String(data: data, encoding: .utf8)
    else { return nil }
    return str
}

private func parsedArgs(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

struct RequestUserInputCard: View {
    let action: MissionAction
    var onSubmit: (String) -> Void

    @State private var answer: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.tint)
                Text("Agent is asking").font(.body.weight(.semibold))
                Spacer()
                Text(action.requestedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(question).font(.callout).textSelection(.enabled)

            if let options, !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(options, id: \.self) { opt in
                        Button(opt) { onSubmit(opt) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                TextField("Your answer", text: $answer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                HStack {
                    Spacer()
                    Button("Submit") { onSubmit(answer) }
                        .buttonStyle(.borderedProminent)
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding()
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var parsedArgs: [String: Any] {
        guard let data = action.argsJSON.data(using: .utf8) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private var question: String {
        (parsedArgs["question"] as? String) ?? "(no question provided)"
    }

    private var options: [String]? {
        parsedArgs["options"] as? [String]
    }
}

