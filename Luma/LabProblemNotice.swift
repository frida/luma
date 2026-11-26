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
                    if let item = item(showing: subject) {
                        Button("Show") { selection = item }
                    }
                    Button("Add to Lab") { engine.addToLab(subject) }
                }
            }
        }
    }

    private func dismiss() {
        engine.dismiss(problem)
    }

    private func item(showing subject: LabSubject) -> SidebarItemID? {
        let sessionID = engine.sessionID(holding: subject)
        switch subject.family {
        case .definition: return .customInstrumentDef(subject.id)
        case .pattern: return .pattern(subject.id.uuidString)
        case .entry: return .notebook
        case .mission: return .mission(subject.id)
        case .session: return sessionID.map(SidebarItemID.session)
        case .instrument: return sessionID.map { .instrument($0, subject.id) }
        case .insight: return sessionID.map { .insight($0, subject.id) }
        case .trace: return sessionID.map { .itrace($0, subject.id) }
        case .replCell: return nil
        case .objectChat, .objectChatMessage: return nil
        }
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
