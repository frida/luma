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
                NotebookEmptyStateView(workspace: workspace)

            case .some(.notebook):
                NotebookView(workspace: workspace, selection: $selection)

            case .some(.repl(let sessionID)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }) {
                    REPLView(sessionID: sessionID, workspace: workspace, selection: $selection)
                        .id(node.sessionRecord.id)
                } else {
                    EmptyView()
                }

            case .some(.instrument(let sessionID, let instID)),
                .some(.instrumentComponent(let sessionID, let instID, _, _)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }),
                    let inst = (try? workspace.store.fetchInstruments(sessionID: sessionID))?.first(where: { $0.id == instID })
                {
                    InstrumentDetailView(instance: inst, workspace: workspace, selection: $selection)
                        .id(inst.id)
                } else {
                    EmptyView()
                }

            case .some(.itraceCapture(let sessionID, let captureID)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }),
                    let capture = (try? workspace.store.fetchITraceCaptures(sessionID: sessionID))?.first(where: { $0.id == captureID })
                {
                    ITraceDetailView(
                        capture: capture, session: node.sessionRecord, workspace: workspace, selection: $selection)
                        .id(capture.id)
                } else {
                    EmptyView()
                }

            case .some(.insight(let sessionID, let insightID)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }),
                    let insight = (try? workspace.store.fetchInsights(sessionID: sessionID))?.first(where: { $0.id == insightID })
                {
                    AddressInsightDetailView(
                        session: node.sessionRecord, insight: insight, workspace: workspace, selection: $selection)
                        .id(insight.id)
                } else {
                    EmptyView()
                }

            case .some(.package(_)):
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
