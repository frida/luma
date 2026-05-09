import Combine
import LumaCore
import SwiftUI

struct DetailView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    var body: some View {
        Group {
            switch selection {
            case .none:
                NotebookEmptyStateView(
                    workspace: workspace,
                    onAddNote: {
                        let note = LumaCore.NotebookEntry(
                            kind: .note,
                            title: "",
                            details: "",
                            binaryData: nil,
                            processName: nil
                        )
                        workspace.engine.addNotebookEntry(note, after: nil)
                        selection = .notebook
                    }
                )

            case .some(.notebook):
                NotebookView(workspace: workspace, selection: $selection)

            case .some(.missions):
                MissionsListView(workspace: workspace, selection: $selection)

            case .some(.mission(let missionID)):
                MissionView(workspace: workspace, missionID: missionID, selection: $selection)
                    .id(missionID)

            case .some(.session(let sessionID)):
                if workspace.engine.sessions.contains(where: { $0.id == sessionID }) {
                    SessionContent(sessionID: sessionID, workspace: workspace) {
                        SessionDetailView(sessionID: sessionID, workspace: workspace, selection: $selection)
                    }
                    .id(sessionID)
                }

            case .some(.repl(let sessionID)):
                if let session = workspace.engine.sessions.first(where: { $0.id == sessionID }) {
                    SessionContent(sessionID: sessionID, workspace: workspace) {
                        REPLView(sessionID: sessionID, workspace: workspace, selection: $selection)
                    }
                    .id(session.id)
                }

            case .some(.instrument(let sessionID, let instID)),
                .some(.instrumentComponent(let sessionID, let instID, _, _)):
                if (try? workspace.store.fetchInstrument(id: instID)) != nil {
                    SessionContent(sessionID: sessionID, workspace: workspace) {
                        InstrumentDetailView(
                            instanceID: instID,
                            sessionID: sessionID,
                            workspace: workspace,
                            selection: $selection
                        )
                    }
                    .id(instID)
                }

            case .some(.itrace(let sessionID, let traceID)):
                let session = workspace.engine.sessions.first(where: { $0.id == sessionID })
                if let session,
                    let trace = (try? workspace.store.fetchITraces(sessionID: sessionID))?.first(where: { $0.id == traceID })
                {
                    SessionContent(sessionID: sessionID, workspace: workspace) {
                        ITraceDetailView(
                            trace: trace, session: session, workspace: workspace, selection: $selection)
                    }
                    .id(trace.id)
                }

            case .some(.insight(let sessionID, let insightID)):
                let session = workspace.engine.sessions.first(where: { $0.id == sessionID })
                if let session,
                    let insight = (try? workspace.store.fetchInsights(sessionID: sessionID))?.first(where: { $0.id == insightID })
                {
                    SessionContent(sessionID: sessionID, workspace: workspace) {
                        AddressInsightDetailView(
                            session: session, insight: insight, workspace: workspace, selection: $selection)
                    }
                    .id(insight.id)
                }

            case .some(.customInstrumentDef(let defID)):
                CustomInstrumentEditorView(defID: defID, workspace: workspace)
                    .id(defID)

            case .some(.package(let packageID)):
                if let package = workspace.engine.installedPackages.first(where: { $0.id == packageID }) {
                    PackageDetailView(package: package, workspace: workspace, selection: $selection)
                        .id(package.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
