import LumaCore
import SwiftUI

struct LabProblemNotice: View {
    let problem: LabProblem
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        switch problem.concern {
        case .objectChat(let chatProblem):
            ObjectChatProblemNotice(problem: chatProblem, chats: engine.objectChats)
        case .missionDeletedInLab, .keptFromLab:
            ProblemNotice(text: problem.reason, onDismiss: dismiss) {}
        case .missionStoppedByOwner(let missionID, _):
            ProblemNotice(text: problem.reason, onDismiss: dismiss) {
                if engine.missions.contains(where: { $0.id == missionID }) {
                    Button("Show") { selection = .mission(missionID) }
                }
            }
        case .copyKeptFromLab(let subject, _):
            ProblemNotice(text: problem.reason, onDismiss: dismiss) {
                if engine.subjectsKeptFromLab.contains(subject) {
                    Button("Show") { selection = item(showing: subject) }
                    Button("Add to Lab") { engine.addToLab(subject) }
                }
            }
        }
    }

    private func dismiss() {
        engine.dismiss(problem)
    }

    private func item(showing subject: LabSubject) -> SidebarItemID {
        subject.family == .pattern ? .pattern(subject.id.uuidString) : .customInstrumentDef(subject.id)
    }
}

struct ProblemNotice<Actions: View>: View {
    let text: String
    let onDismiss: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.caption)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    actions
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
    }
}
