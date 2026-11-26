import LumaCore
import SwiftUI
import SwiftyPharo

struct PharoChatToolCallCard: View {
    let call: ObjectChatToolCall
    let engine: Engine
    let onSelect: (PharoObject) -> Void

    @State private var isRejecting = false
    @State private var rejectReason = ""
    @State private var showsSnapshot = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.tint)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
            }
            details
            outcome
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .alert("Reject this call?", isPresented: $isRejecting) {
            TextField("Reason (optional)", text: $rejectReason)
            Button("Reject", role: .destructive) {
                chats.reject(call.id, reason: rejectReason.isEmpty ? nil : rejectReason)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tell the assistant why you rejected it. This signal can help it adjust.")
        }
    }

    private var symbol: String {
        switch call.tool {
        case ObjectChats.evaluateTool: "chevron.left.forwardslash.chevron.right"
        case ObjectChats.viewTool: "eye"
        case ObjectChats.objectsTool: "list.bullet"
        default: "wrench.adjustable.fill"
        }
    }

    private var title: String {
        switch call.tool {
        case ObjectChats.evaluateTool: "Evaluate"
        case ObjectChats.viewTool: "Read a view"
        case ObjectChats.objectsTool: "List the objects"
        default: call.tool
        }
    }

    @ViewBuilder
    private var details: some View {
        switch call.tool {
        case ObjectChats.evaluateTool:
            PharoStyledSource(source: code, errorPosition: call.status == .failed ? call.errorPosition : nil)
            ForEach(bindings, id: \.name) { binding in
                HStack(spacing: 4) {
                    Text("\(binding.name) →")
                    objectID(binding.objectID)
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
        case ObjectChats.viewTool:
            HStack(spacing: 4) {
                Text("\(argument("view")) of")
                objectID(argument("object_id"))
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        case ObjectChats.objectsTool:
            EmptyView()
        default:
            Text(argumentsJSON)
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch call.status {
        case .proposed:
            if chats.isExecutor(of: call) {
                HStack {
                    Button("Reject", role: .destructive) {
                        rejectReason = ""
                        isRejecting = true
                    }
                    Spacer()
                    if chats.canRun(call) {
                        runButton
                    } else {
                        ExecutorWaitNote(executorName: executorName, hold: chats.hold(on: call))
                    }
                }
            } else if let hold = chats.hold(on: call) {
                held(hold)
            } else {
                ExecutorWaitNote(executorName: executorName, hold: nil)
            }
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded:
            if call.tool == ObjectChats.evaluateTool, let objectID = call.objectID {
                result(objectID)
            } else {
                Text(call.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .failed:
            Text(call.error ?? call.summary ?? "It failed.")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .rejected:
            Text(call.error.map { "Rejected: \($0)" } ?? "Rejected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runButton: some View {
        HStack(spacing: 4) {
            if call.tool == ObjectChats.evaluateTool {
                Menu {
                    Button("Run, and Run My Expressions Without Asking") {
                        ObjectChatRunSetting.shared.runsWithoutAsking = true
                        run()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More ways to run")
                .accessibilityIdentifier("chat.call.runOptions")
            }
            Button("Run", action: run)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chat.call.run")
        }
    }

    private func run() {
        Task { await chats.run(call.id) }
    }

    private func held(_ hold: ObjectChatCallHold) -> some View {
        HStack {
            ExecutorWaitNote(executorName: executorName, hold: hold)
            Spacer()
            if chats.isAsker(of: call) {
                Button("Cancel") { chats.reject(call.id, reason: "Canceled while waiting: \(hold.reason(executorName: executorName))") }
                    .accessibilityIdentifier("chat.call.cancel")
            }
        }
    }

    private var chats: ObjectChats {
        engine.objectChats
    }

    private var executorName: String {
        call.executor?.name ?? "the session's host"
    }

    @ViewBuilder
    private func result(_ objectID: String) -> some View {
        let isLive = chats.isLive(objectID, in: call.chatID)
        Button {
            if isLive {
                open(objectID)
            } else {
                showsSnapshot.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: isLive ? "arrow.right.circle" : (showsSnapshot ? "chevron.down" : "chevron.right"))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    self.objectID(objectID)
                    Text(": \(printString(of: objectID))")
                        .multilineTextAlignment(.leading)
                }
            }
            .font(.callout.monospaced())
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .platformPointer(.link)
        .help(isLive ? "Open in the next pane" : "Show what it was when it was made")
        .accessibilityIdentifier("chat.call.result")
        if !isLive, showsSnapshot {
            if let snapshot = chats.thread(of: call.chatID).objects.first(where: { $0.objectID == objectID })?.snapshot {
                PharoSnapshotView(snapshot: snapshot)
                    .frame(height: 220)
                    .pharoPane()
            }
            Button("Run Again") { runAgain() }
                .accessibilityIdentifier("chat.call.runAgain")
        }
    }

    private func open(_ objectID: String) {
        Task {
            do {
                let object = try await chats.open(objectID, in: call.chatID)
                failure = nil
                onSelect(object)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func runAgain() {
        Task {
            do {
                try await chats.runAgain(call.id)
                failure = nil
                showsSnapshot = false
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func objectID(_ objectID: String) -> some View {
        PharoChatObjectID(objectID: objectID, collaboration: engine.collaboration)
    }

    private func printString(of objectID: String) -> String {
        let summary = call.summary ?? ""
        let prefix = "\(objectID): "
        return summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary
    }

    private var code: String {
        argument("code")
    }

    private var bindings: [(name: String, objectID: String)] {
        guard case .array(let listed) = call.args["bindings"] else { return [] }
        return listed.compactMap {
            guard case .object(let binding) = $0, case .string(let name) = binding["name"],
                case .string(let objectID) = binding["object_id"]
            else { return nil }
            return (name, objectID)
        }
    }

    private func argument(_ name: String) -> String {
        if case .string(let value) = call.args[name] { return value }
        return ""
    }

    private var argumentsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try! encoder.encode(call.args), as: UTF8.self)
    }
}
