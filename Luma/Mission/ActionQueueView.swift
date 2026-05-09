import LumaCore
import SwiftUI

struct ActionQueueView: View {
    @ObservedObject var workspace: Workspace
    let missionID: UUID
    let actions: [MissionAction]

    @State private var rejectingAction: MissionAction?
    @State private var rejectReason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "tray.full")
                Text("Action Queue").font(.headline)
                Spacer()
                Text("\(actions.count) pending").font(.caption).foregroundStyle(.secondary)
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
                                    workspace.engine.submitUserInputResponse(actionID: action.id, answer: answer)
                                }
                            } else {
                                ActionCard(
                                    action: action,
                                    onApprove: { Task { await workspace.engine.approveMissionAction(actionID: action.id) } },
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert("Reject action?", isPresented: Binding(
            get: { rejectingAction != nil },
            set: { if !$0 { rejectingAction = nil } }
        )) {
            TextField("Reason (optional)", text: $rejectReason)
            Button("Reject", role: .destructive) {
                if let a = rejectingAction {
                    let reason = rejectReason.isEmpty ? nil : rejectReason
                    Task { await workspace.engine.rejectMissionAction(actionID: a.id, reason: reason) }
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

private struct ActionCard: View {
    let action: MissionAction
    var onApprove: () -> Void
    var onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wrench.adjustable.fill").foregroundStyle(.tint)
                Text(action.toolName).font(.body.monospaced().weight(.semibold))
                Spacer()
                Text(action.requestedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }

            if !action.argsJSON.isEmpty, action.argsJSON != "{}" {
                Text(prettyJSON(action.argsJSON))
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

private struct RequestUserInputCard: View {
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

private func prettyJSON(_ s: String) -> String {
    guard let data = s.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
        let str = String(data: pretty, encoding: .utf8)
    else { return s }
    return str
}
